-- WhatsApp tab: Google Sheet links per funnel. Every minute new rows become leads
-- (read through a Google service account the sheet is shared with).

create table public.funnel_sheets (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references public.tenants (id) on delete cascade,
  funnel_id        uuid not null references public.funnels (id) on delete cascade,
  name             text not null check (length(trim(name)) > 0),
  sheet_url        text not null,
  spreadsheet_id   text not null,
  gid              text,
  -- true: rows already in the sheet are imported on the first sync; false: only rows added later
  import_existing  boolean not null default false,
  field_map        jsonb not null default '{}',
  headers          jsonb,
  sample           jsonb,
  -- data rows already handled (null = first sync not done yet)
  synced_rows      int,
  last_synced_at   timestamptz,
  last_error       text,
  leads_added      int not null default 0,
  leads_updated    int not null default 0,
  rows_skipped     int not null default 0,
  is_active        boolean not null default true,
  created_at       timestamptz not null default now()
);
create index funnel_sheets_funnel_idx on public.funnel_sheets (funnel_id);
create index funnel_sheets_tenant_idx on public.funnel_sheets (tenant_id);

alter table public.funnel_sheets enable row level security;
create policy "funnel_sheets: read" on public.funnel_sheets for select to authenticated
  using (exists (select 1 from public.funnels f where f.id = funnel_sheets.funnel_id
                 and (private.can_access_business(f.business_id) or private.has_permission(f.tenant_id, 'funnels', 'view'))));
create policy "funnel_sheets: write" on public.funnel_sheets for all to authenticated
  using (private.has_permission(tenant_id, 'funnels', 'edit'))
  with check (private.has_permission(tenant_id, 'funnels', 'edit'));
grant select, insert, update, delete on public.funnel_sheets to authenticated;
revoke all on public.funnel_sheets from anon;

-- which sheet a lead / submission came from
alter table public.leads add column sheet_id uuid references public.funnel_sheets (id) on delete set null;
alter table public.lead_submissions add column sheet_id uuid references public.funnel_sheets (id) on delete set null;
alter table public.lead_submissions drop constraint lead_submissions_via_check;
alter table public.lead_submissions add constraint lead_submissions_via_check check (via in ('webhook', 'import', 'sheet'));

-- ingest_lead(): a sheet row gets the WhatsApp source and its own activity text
do $$
declare
  d text := pg_get_functiondef('private.ingest_lead(uuid,uuid,uuid,uuid,jsonb,text,boolean,uuid)'::regprocedure);
  r text[][] := array[
    array['case when p_via = ''webhook'' then ''Website'' else ''Other'' end',
          'case when p_via = ''webhook'' then ''Website'' when p_via = ''sheet'' then ''WhatsApp'' else ''Other'' end'],
    array['case when p_via = ''import'' then ''Imported'' || coalesce',
          'case when p_via = ''sheet'' then ''Added from the Google Sheet'' || coalesce('' ('' || pg_name || '')'', '''') when p_via = ''import'' then ''Imported'' || coalesce'],
    array['case when p_via = ''import'' then ''Updated by an import''',
          'case when p_via = ''sheet'' then ''Updated from the Google Sheet'' || coalesce('' ('' || pg_name || '')'', '''') when p_via = ''import'' then ''Updated by an import''']
  ];
  i int;
begin
  for i in 1 .. array_length(r, 1) loop
    if position(r[i][1] in d) = 0 then raise exception 'ingest_lead patch % did not apply', i; end if;
    d := replace(d, r[i][1], r[i][2]);
  end loop;
  execute d;
end $$;

-- rows read from a sheet → leads (called by the sheets-sync function with the service role)
-- p_first: the sheet row number of the first row (for error messages)
create or replace function public.sheet_ingest(p_sheet uuid, p_rows jsonb, p_first int default 2)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  s        public.funnel_sheets;
  r        jsonb;
  d        jsonb;
  res      jsonb;
  lid      uuid;
  miss     text[];
  added    int := 0;
  updated  int := 0;
  skipped  int := 0;
  n        int := 0;
  err      text;
begin
  select * into s from public.funnel_sheets where id = p_sheet;
  if s.id is null then raise exception 'Sheet not found.'; end if;

  for r in select value from jsonb_array_elements(coalesce(p_rows, '[]')) loop
    n := n + 1;
    -- blank rows are passed over
    if not exists (select 1 from jsonb_each_text(r) e where coalesce(trim(e.value), '') <> '') then continue; end if;
    begin
      d := private.map_lead_fields(r, s.field_map);
      if coalesce(d ->> 'name', '') = '' and coalesce(d ->> 'first_name', '') <> '' then
        d := d || jsonb_build_object('name', trim(concat_ws(' ', d ->> 'first_name', d ->> 'last_name')));
      end if;
      d := d - 'first_name' - 'last_name';
      miss := '{}';
      if coalesce(d ->> 'name', '') = '' then miss := miss || 'name'; end if;
      if coalesce(d ->> 'email', '') = '' then miss := miss || 'email'; end if;
      if coalesce(d ->> 'phone', '') = '' then miss := miss || 'phone'; end if;
      if array_length(miss, 1) > 0 then raise exception 'missing %', array_to_string(miss, ', '); end if;
      if (d ->> 'email') !~ '^[^\s@]+@[^\s@]+\.[^\s@]+$' then raise exception 'invalid email'; end if;
      if length(private.norm_phone(d ->> 'phone')) < 10 then raise exception 'invalid phone'; end if;

      res := private.ingest_lead(null, s.funnel_id, null, null, d, 'sheet', true, null);
      lid := (res ->> 'lead_id')::uuid;
      update public.leads set sheet_id = s.id where id = lid and sheet_id is null;
      update public.lead_submissions set sheet_id = s.id
      where id = (select ls.id from public.lead_submissions ls where ls.lead_id = lid order by ls.created_at desc limit 1);
      if res ->> 'status' = 'created' then added := added + 1; else updated := updated + 1; end if;
    exception when others then
      skipped := skipped + 1;
      err := 'Row ' || (p_first + n - 1) || ': ' || sqlerrm;
    end;
  end loop;

  update public.funnel_sheets set
    synced_rows    = coalesce(synced_rows, 0) + jsonb_array_length(coalesce(p_rows, '[]')),
    leads_added    = leads_added + added,
    leads_updated  = leads_updated + updated,
    rows_skipped   = rows_skipped + skipped,
    last_synced_at = now(),
    last_error     = case when skipped > 0 then err when n > 0 then null else last_error end
  where id = s.id;

  return jsonb_build_object('added', added, 'updated', updated, 'skipped', skipped);
end;
$$;
revoke all on function public.sheet_ingest(uuid, jsonb, int) from public, anon, authenticated;
grant execute on function public.sheet_ingest(uuid, jsonb, int) to service_role;

-- ---- applied as sheets_sync_cron ----
create extension if not exists pg_cron;
create extension if not exists pg_net;

-- shared secret between the cron job and the sheets-sync function (kept in the vault)
select vault.create_secret(replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''), 'sheets_cron_secret', 'sheets-sync cron call');

create or replace function public.sheets_cron_secret()
returns text
language sql
security definer
set search_path = ''
as $$ select decrypted_secret from vault.decrypted_secrets where name = 'sheets_cron_secret' limit 1 $$;
revoke all on function public.sheets_cron_secret() from public, anon, authenticated;
grant execute on function public.sheets_cron_secret() to service_role;

-- every minute, only when some sheet is switched on
select cron.schedule('sheets-sync', '* * * * *', $job$
  select net.http_post(
    url := 'https://tnnjudehqalkgglzkfik.supabase.co/functions/v1/sheets-sync',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-secret', public.sheets_cron_secret()),
    body := '{"action":"cron"}'::jsonb,
    timeout_milliseconds := 55000
  )
  where exists (select 1 from public.funnel_sheets where is_active)
$job$);
