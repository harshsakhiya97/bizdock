-- Callyzer → Team numbers: every call of every staff number (not only calls to leads), for the recording-health report.
-- Filled by callyzer_ingest alongside public.calls (which keeps only calls to lead numbers).
create table public.callyzer_team_calls (
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  external_id text not null,
  emp_number text,
  emp_name text,
  client_number text,
  call_type text,
  call_method text,
  call_mode text,
  duration_sec int not null default 0,
  started_at timestamptz not null,
  recording_url text,
  primary key (tenant_id, external_id)
);
create index callyzer_team_calls_time on public.callyzer_team_calls (tenant_id, started_at desc);
alter table public.callyzer_team_calls enable row level security;
create policy "callyzer_team_calls: read" on public.callyzer_team_calls for select to authenticated
  using (private.has_permission(tenant_id, 'call_logs', 'view') or private.has_permission(tenant_id, 'settings', 'edit'));

create or replace function private.callyzer_ingest(p_tenant uuid, p_rows jsonb)
 returns integer language plpgsql security definer set search_path to '' as $function$
declare
  n int;
begin
  -- every call, for the team report
  insert into public.callyzer_team_calls (tenant_id, external_id, emp_number, emp_name, client_number, call_type, call_method, call_mode, duration_sec, started_at, recording_url)
  select p_tenant, r ->> 'id',
         nullif(right(regexp_replace(coalesce(r ->> 'emp_number', ''), '\D', '', 'g'), 10), ''),
         nullif(r ->> 'emp_name', ''),
         nullif(right(regexp_replace(coalesce(r ->> 'client_number', ''), '\D', '', 'g'), 10), ''),
         lower(nullif(r ->> 'call_type', '')), nullif(r ->> 'call_method', ''), nullif(r ->> 'call_mode', ''),
         coalesce(nullif(r ->> 'duration', '')::numeric::int, 0),
         coalesce(((r ->> 'call_date') || ' ' || coalesce(nullif(r ->> 'call_time', ''), '00:00:00'))::timestamp at time zone 'Asia/Kolkata', now()),
         nullif(r ->> 'call_recording_url', '')
    from jsonb_array_elements(p_rows) r
   where coalesce(r ->> 'id', '') <> ''
  on conflict (tenant_id, external_id) do update set
    duration_sec = excluded.duration_sec,
    emp_name = coalesce(excluded.emp_name, public.callyzer_team_calls.emp_name),
    recording_url = coalesce(excluded.recording_url, public.callyzer_team_calls.recording_url);

  with src as (
    select r,
           right(regexp_replace(coalesce(r ->> 'client_number', ''), '\D', '', 'g'), 10) as ph,
           right(regexp_replace(coalesce(r ->> 'emp_number', ''), '\D', '', 'g'), 10) as emp
      from jsonb_array_elements(p_rows) r
     where coalesce(r ->> 'id', '') <> ''
  ), matched as (
    select s.*,
           (select l.id from public.leads l
             where l.tenant_id = p_tenant and right(regexp_replace(coalesce(l.phone, ''), '\D', '', 'g'), 10) = s.ph
             order by l.created_at desc limit 1) as lid,
           (select m.id from public.tenant_members m join public.profiles p on p.id = m.user_id
             where m.tenant_id = p_tenant and length(s.emp) = 10 and right(regexp_replace(coalesce(p.phone, ''), '\D', '', 'g'), 10) = s.emp
             limit 1) as mid
      from src s
     where length(s.ph) = 10
  ), ins as (
    insert into public.calls (tenant_id, business_id, sub_business_id, lead_id, member_id, phone, agent_phone, direction, started_at, duration_sec,
                              recording_url, call_method, call_mode, emp_name, client_name, source, external_id)
    select p_tenant, l.business_id, l.sub_business_id, m.lid, m.mid, m.ph, nullif(m.emp, ''),
           case lower(coalesce(m.r ->> 'call_type', '')) when 'incoming' then 'incoming' when 'outgoing' then 'outgoing' when 'missed' then 'missed'
                when 'rejected' then 'rejected' else 'unknown' end,
           coalesce(((m.r ->> 'call_date') || ' ' || coalesce(nullif(m.r ->> 'call_time', ''), '00:00:00'))::timestamp at time zone 'Asia/Kolkata', now()),
           nullif(m.r ->> 'duration', '')::numeric::int, nullif(m.r ->> 'call_recording_url', ''),
           nullif(m.r ->> 'call_method', ''), nullif(m.r ->> 'call_mode', ''), nullif(m.r ->> 'emp_name', ''), nullif(m.r ->> 'client_name', ''),
           'callyzer', m.r ->> 'id'
      from matched m join public.leads l on l.id = m.lid
     where m.lid is not null
    on conflict (tenant_id, source, external_id) where external_id is not null do update set
      duration_sec = excluded.duration_sec,
      recording_url = coalesce(excluded.recording_url, public.calls.recording_url),
      emp_name = coalesce(excluded.emp_name, public.calls.emp_name),
      member_id = coalesce(public.calls.member_id, excluded.member_id)
    returning 1)
  select count(*) into n from ins;
  return n;
end $function$;

/**
 * Team numbers report for a period: per staff number — total, not connected, normal (phone) connected, WhatsApp connected,
 * recordings on Callyzer, missing, connected after the last recording, last connected, last recording.
 */
create or replace function public.callyzer_team_report(p_tenant uuid, p_from timestamptz, p_to timestamptz)
returns table (emp_number text, emp_name text, total int, not_connected int, normal_connected int, whatsapp int,
               on_callyzer int, after_last_rec int, last_connected timestamptz, last_recording timestamptz)
language sql stable security definer set search_path to '' as $$
  with c as (
    select * from public.callyzer_team_calls
     where tenant_id = p_tenant and started_at >= p_from and started_at < p_to and emp_number is not null
       and (private.has_permission(p_tenant, 'call_logs', 'view') or private.has_permission(p_tenant, 'settings', 'edit'))
  ), g as (
    select c.emp_number,
           (array_agg(c.emp_name order by c.started_at desc) filter (where c.emp_name is not null))[1] as emp_name,
           count(*)::int as total,
           count(*) filter (where c.duration_sec = 0)::int as not_connected,
           count(*) filter (where c.duration_sec > 0 and c.call_method = 'PhoneCall')::int as normal_connected,
           count(*) filter (where c.duration_sec > 0 and c.call_method = 'WhatsAppCall')::int as whatsapp,
           count(*) filter (where c.duration_sec > 0 and c.call_method = 'PhoneCall' and c.recording_url is not null)::int as on_callyzer,
           max(c.started_at) filter (where c.duration_sec > 0 and c.call_method = 'PhoneCall') as last_connected,
           max(c.started_at) filter (where c.recording_url is not null) as last_recording
      from c group by c.emp_number
  )
  select g.emp_number, g.emp_name, g.total, g.not_connected, g.normal_connected, g.whatsapp, g.on_callyzer,
         (select count(*) from c where c.emp_number = g.emp_number and c.duration_sec > 0 and c.call_method = 'PhoneCall'
             and c.recording_url is null and (g.last_recording is null or c.started_at > g.last_recording))::int,
         g.last_connected, g.last_recording
    from g
   order by g.total desc
$$;
revoke all on function public.callyzer_team_report(uuid, timestamptz, timestamptz) from public, anon;
grant execute on function public.callyzer_team_report(uuid, timestamptz, timestamptz) to authenticated;

-- pull the last 90 days again, so the report has every call (calls to leads are only updated)
update public.integrations
   set config = config || jsonb_build_object('synced_until', (extract(epoch from now() - interval '90 days'))::bigint::text, 'cursor', '')
 where provider = 'callyzer';
