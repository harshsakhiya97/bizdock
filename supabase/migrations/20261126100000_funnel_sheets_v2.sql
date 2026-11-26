-- Funnel → Sheets (was WhatsApp): Google Sheets → leads.
--  * only the phone is needed: no name → the phone is the name; a wrong or missing email is left out
--  * the source is "Google Sheet" (was WhatsApp)
--  * no fixed Perisclaw columns any more: the sheet's own column mapping only (copied into each sheet's mapping first)
--  * every skipped row is kept (row number, data, reason) to list and sync again; total_rows = data rows in the sheet
--  * modes: new (the next rows), retry (given rows again), recheck (rows already handled: only phones not yet a lead)
alter table public.funnel_sheets add column if not exists total_rows int;

create table if not exists public.sheet_skipped_rows (
  id bigserial primary key,
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  sheet_id uuid not null references public.funnel_sheets(id) on delete cascade,
  row_no int not null,
  data jsonb not null default '{}',
  reason text,
  skipped_at timestamptz not null default now(),
  resolved_at timestamptz,
  unique (sheet_id, row_no)
);
alter table public.sheet_skipped_rows enable row level security;
create policy "sheet_skipped_rows: read" on public.sheet_skipped_rows for select using (
  exists (select 1 from public.funnel_sheets s where s.id = sheet_skipped_rows.sheet_id)
);
grant select on public.sheet_skipped_rows to authenticated;

-- the fixed Perisclaw columns kept for the sheets that have them in row 1 (the saved mapping wins)
update public.funnel_sheets s set field_map = coalesce((
    select jsonb_object_agg(e.key, e.value)
      from jsonb_each('{"Sr No":"ignore","Name":"name","Email":"email","Contact No":"phone","City":"city","Purpose":"purpose","Reason":"note"}'::jsonb) e
     where coalesce(s.headers, '[]'::jsonb) ? e.key), '{}'::jsonb) || coalesce(s.field_map, '{}'::jsonb);

-- leads from sheets: source Google Sheet (was WhatsApp)
do $$
declare t uuid;
begin
  for t in select distinct l.tenant_id from public.leads l where l.sheet_id is not null loop
    insert into public.lead_sources (tenant_id, name, sort_order)
    values (t, 'Google Sheet', coalesce((select max(sort_order) + 1 from public.lead_sources where tenant_id = t), 1))
    on conflict (tenant_id, name) do nothing;
    update public.leads l set source_id = (select id from public.lead_sources where tenant_id = t and name = 'Google Sheet')
     where l.tenant_id = t and l.sheet_id is not null
       and l.source_id in (select id from public.lead_sources where tenant_id = t and name = 'WhatsApp');
  end loop;
end $$;

drop function if exists public.sheet_ingest(uuid, jsonb, integer);
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
revoke all on function public.sheet_ingest(uuid, jsonb, integer, text, integer[]) from public, anon, authenticated;
grant execute on function public.sheet_ingest(uuid, jsonb, integer, text, integer[]) to service_role;
