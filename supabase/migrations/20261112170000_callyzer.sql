-- Callyzer: call logs pulled every 5 minutes with the workspace's API key, kept only when the receiver's number
-- is a lead's number, and shown on that lead (Follow-ups → Callyzer). Phone calls and WhatsApp calls.

alter table public.calls add column if not exists call_method text; -- 'PhoneCall' | 'WhatsAppCall'
alter table public.calls add column if not exists call_mode text;   -- 'Voice' | 'Video'
alter table public.calls add column if not exists emp_name text;
alter table public.calls add column if not exists client_name text;
create index if not exists calls_tenant_phone on public.calls (tenant_id, phone, started_at desc);

-- a batch of Callyzer call logs → calls (only numbers that are a lead's); returns how many were saved
create or replace function private.callyzer_ingest(p_tenant uuid, p_rows jsonb) returns int
language plpgsql security definer set search_path = '' as $$
declare
  n int;
begin
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
end $$;
revoke all on function private.callyzer_ingest(uuid, jsonb) from public, anon, authenticated;

-- for the edge function (service role)
create or replace function public.callyzer_ingest(p_tenant uuid, p_rows jsonb) returns int
language sql security definer set search_path = '' as $$ select private.callyzer_ingest(p_tenant, p_rows) $$;
revoke all on function public.callyzer_ingest(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.callyzer_ingest(uuid, jsonb) to service_role;

-- the edge function, called every 5 minutes while a workspace has Callyzer connected
create or replace function private.kick_callyzer(p_body jsonb) returns void
language sql security definer set search_path = '' as $$
  select net.http_post(
    url := 'https://tnnjudehqalkgglzkfik.supabase.co/functions/v1/callyzer',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-secret', public.workflow_cron_secret()),
    body := p_body,
    timeout_milliseconds := 150000
  );
$$;

do $$
begin
  perform cron.unschedule('callyzer-pull') where exists (select 1 from cron.job where jobname = 'callyzer-pull');
  perform cron.schedule('callyzer-pull', '*/5 * * * *', $c$
    select private.kick_callyzer('{"action":"cron"}'::jsonb)
     where exists (select 1 from public.integrations where provider = 'callyzer' and is_enabled and status = 'connected');
  $c$);
end $$;

-- the Paid Podcast leads list: connected calls by the lead's number (a Callyzer call belongs to every lead with that number)
create or replace function public.lead_list_extras(p_tenant uuid, p_sub uuid)
returns table (
  lead_id uuid,
  last_note text,
  last_note_at timestamptz,
  fu_done int,
  connected int,
  pending_fu_id uuid,
  meeting_status text,
  meeting_link text,
  meeting_date date,
  meeting_time time
)
language sql stable security invoker set search_path = '' as $$
  select l.id,
         n.note, n.created_at,
         coalesce(f.done, 0)::int, coalesce(c.connected, 0)::int, f.pending_id,
         m.status, m.link, m.meeting_date, m.start_time
    from public.leads l
    left join lateral (
      select a.note, a.created_at from public.lead_activities a
       where a.lead_id = l.id and a.kind = 'note' and coalesce(a.note, '') <> ''
       order by a.created_at desc limit 1) n on true
    left join lateral (
      select count(*) filter (where fu.status = 'done') as done,
             (array_agg(fu.id order by fu.due_at) filter (where fu.status = 'pending'))[1] as pending_id
        from public.follow_ups fu where fu.lead_id = l.id) f on true
    left join lateral (
      select count(*) as connected from public.calls k
       where k.tenant_id = l.tenant_id and k.phone = right(regexp_replace(coalesce(l.phone, ''), '\D', '', 'g'), 10)
         and coalesce(k.duration_sec, 0) > 0) c on true
    left join lateral (
      select mt.status, mt.link, mt.meeting_date, mt.start_time from public.meetings mt
       where mt.lead_id = l.id order by mt.meeting_date desc, mt.start_time desc limit 1) m on true
   where l.tenant_id = p_tenant and l.sub_business_id = p_sub;
$$;
