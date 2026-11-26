-- Sheets → column mapping: "Lead date" — a sheet column (e.g. Date-Time) gives a new lead its date instead of the
-- sync time. Read as India time: 24/11/2026 12:53 PM, 24-11-2026 14:05, 24/11/26, 2026-11-24 12:53, ISO.
-- A date that can't be read (or is in the future) is kept as an extra field "Lead date".
create or replace function private.parse_sheet_date(t text) returns timestamptz
language plpgsql stable set search_path = '' as $$
declare
  v text := trim(coalesce(t, ''));
  m text[];
  h int;
  tm time := '00:00';
  ts timestamptz;
begin
  if v = '' then return null; end if;
  m := regexp_match(v, '^(\d{1,2})[/.-](\d{1,2})[/.-](\d{2,4})(?:[ T,]+(\d{1,2}):(\d{2})(?::(\d{2}))?\s*([AaPp][Mm])?)?$');
  if m is not null then
    if m[4] is not null then
      h := m[4]::int;
      if m[7] ilike 'pm' and h < 12 then h := h + 12; elsif m[7] ilike 'am' and h = 12 then h := 0; end if;
      tm := make_time(h, m[5]::int, coalesce(m[6], '0')::int);
    end if;
    ts := (make_date(case when length(m[3]) = 2 then 2000 + m[3]::int else m[3]::int end, m[2]::int, m[1]::int) + tm) at time zone 'Asia/Kolkata';
  elsif v ~ '^\d{4}-\d{1,2}-\d{1,2}' then
    ts := case when v ~ '(Z|[+-]\d{2}:?\d{2})$' then v::timestamptz else v::timestamp at time zone 'Asia/Kolkata' end;
  end if;
  if ts > now() + interval '1 day' or ts < '2000-01-01' then return null; end if;
  return ts;
exception when others then
  return null;
end $$;

create or replace function public.sheet_ingest(p_sheet uuid, p_rows jsonb, p_first integer default 2, p_mode text default 'new', p_row_nos integer[] default null)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  s        public.funnel_sheets;
  r        jsonb;
  d        jsonb;
  res      jsonb;
  lid      uuid;
  rn       int;
  ph       text;
  ld       timestamptz;
  added    int := 0;
  updated  int := 0;
  skipped  int := 0;
  existing int := 0;
  n        int := 0;
  err      text;
begin
  select * into s from public.funnel_sheets where id = p_sheet;
  if s.id is null then raise exception 'Sheet not found.'; end if;

  for r in select value from jsonb_array_elements(coalesce(p_rows, '[]')) loop
    n := n + 1;
    rn := coalesce(p_row_nos[n], p_first + n - 1);
    if not exists (select 1 from jsonb_each_text(r) e where coalesce(trim(e.value), '') <> '') then continue; end if;
    begin
      d := private.map_lead_fields((select coalesce(jsonb_object_agg(case when coalesce(s.field_map, '{}') ? e.key then e.key
                 else trim(both '_' from lower(regexp_replace(trim(e.key), '[^a-zA-Z0-9]+', '_', 'g'))) end, e.value), '{}')
             from jsonb_each(r) e), coalesce(s.field_map, '{}'));
      if coalesce(d ->> 'name', '') = '' and coalesce(d ->> 'first_name', '') <> '' then
        d := d || jsonb_build_object('name', trim(concat_ws(' ', d ->> 'first_name', d ->> 'last_name')));
      end if;
      d := d - 'first_name' - 'last_name';
      -- Lead date: the column's date becomes a new lead's date (unreadable: kept as an extra field)
      ld := null;
      if coalesce(trim(d ->> 'lead_date'), '') <> '' then
        ld := private.parse_sheet_date(d ->> 'lead_date');
        if ld is null then d := d || jsonb_build_object('Lead date', d ->> 'lead_date'); end if;
      end if;
      d := d - 'lead_date';
      ph := trim(coalesce(d ->> 'phone', ''));
      if ph = '' then raise exception 'no phone number'; end if;
      if length(private.norm_phone(ph)) < 10 then raise exception 'not a valid phone number (%)', ph; end if;
      if coalesce(trim(d ->> 'name'), '') = '' then d := d || jsonb_build_object('name', ph); end if;
      if coalesce(d ->> 'email', '') <> '' and (d ->> 'email') !~ '^[^\s@]+@[^\s@]+\.[^\s@]+$' then d := d - 'email'; end if;
      if coalesce(trim(d ->> 'lead_source'), '') = '' then d := d || jsonb_build_object('lead_source', 'Google Sheet'); end if;

      if p_mode = 'recheck' and exists (select 1 from public.leads l where l.funnel_id = s.funnel_id and not l.is_archived
                                          and private.norm_phone(l.phone) = private.norm_phone(ph)) then
        existing := existing + 1;
        update public.sheet_skipped_rows set resolved_at = now() where sheet_id = s.id and row_no = rn and resolved_at is null;
        continue;
      end if;

      res := private.ingest_lead(null, s.funnel_id, null, null, d, 'sheet', true, null);
      lid := (res ->> 'lead_id')::uuid;
      update public.leads set sheet_id = s.id where id = lid and sheet_id is null;
      if ld is not null and res ->> 'status' = 'created' then update public.leads set created_at = ld where id = lid; end if;
      update public.lead_submissions set sheet_id = s.id
      where id = (select ls.id from public.lead_submissions ls where ls.lead_id = lid order by ls.created_at desc limit 1);
      if res ->> 'status' = 'created' then added := added + 1; else updated := updated + 1; end if;
      update public.sheet_skipped_rows set resolved_at = now() where sheet_id = s.id and row_no = rn and resolved_at is null;
    exception when others then
      skipped := skipped + 1;
      err := 'Row ' || rn || ': ' || sqlerrm;
      insert into public.sheet_skipped_rows (tenant_id, sheet_id, row_no, data, reason)
      values (s.tenant_id, s.id, rn, r, sqlerrm)
      on conflict (sheet_id, row_no) do update set data = excluded.data, reason = excluded.reason, skipped_at = now(), resolved_at = null;
    end;
  end loop;

  update public.funnel_sheets set
    synced_rows    = case when p_mode = 'new' then coalesce(synced_rows, 0) + jsonb_array_length(coalesce(p_rows, '[]')) else synced_rows end,
    leads_added    = leads_added + added,
    leads_updated  = leads_updated + updated,
    rows_skipped   = (select count(*) from public.sheet_skipped_rows x where x.sheet_id = s.id and x.resolved_at is null),
    last_synced_at = now(),
    last_error     = case when skipped > 0 then err when n > 0 then null else last_error end
  where id = s.id;

  return jsonb_build_object('added', added, 'updated', updated, 'skipped', skipped, 'existing', existing);
end;
$$;
