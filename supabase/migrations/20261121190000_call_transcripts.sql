-- Call transcripts: every Callyzer call recording (our copy in call-recordings) is transcribed by Gemini (the
-- workspace's key, counted in ai_usage as call_transcript, stops at its monthly limit). Newest first, the backlog too.
-- Edge function call-transcribe: cron (every minute while some wait) and redo (Regenerate, from the app).
alter table public.calls
  add column if not exists transcript_status text check (transcript_status in ('waiting', 'done', 'error', 'skipped')),
  add column if not exists transcript_tries integer not null default 0,
  add column if not exists transcript_error text,
  add column if not exists transcript_at timestamptz,
  add column if not exists transcript_lease timestamptz;
create index if not exists calls_transcript_todo on public.calls (started_at desc)
  where source = 'callyzer' and recording_path is not null and transcript_status is null;

-- the next calls to transcribe (held for 3 minutes)
create or replace function public.call_transcript_claim(p_limit integer default 5) returns setof uuid
language sql volatile security definer set search_path = '' as $$
  update public.calls set transcript_lease = now() + interval '3 minutes'
  where id in (
    select id from public.calls
    where source = 'callyzer' and recording_path is not null and coalesce(duration_sec, 0) >= 5
      and (transcript_status is null or transcript_status = 'waiting') and transcript_tries < 3
      and (transcript_lease is null or transcript_lease < now())
    order by started_at desc
    limit p_limit
    for update skip locked
  )
  returning id
$$;
revoke all on function public.call_transcript_claim(integer) from public, anon, authenticated;

create or replace function private.kick_call_transcribe() returns void
language sql security definer set search_path = '' as $$
  select net.http_post(
    url := 'https://tnnjudehqalkgglzkfik.supabase.co/functions/v1/call-transcribe',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-secret', public.workflow_cron_secret()),
    body := '{"action":"cron"}'::jsonb,
    timeout_milliseconds := 60000
  );
$$;
select cron.schedule('call-transcribe', '* * * * *', $c$
  select private.kick_call_transcribe()
  where exists (select 1 from public.calls
                where source = 'callyzer' and recording_path is not null and coalesce(duration_sec, 0) >= 5
                  and (transcript_status is null or transcript_status = 'waiting') and transcript_tries < 3
                  and (transcript_lease is null or transcript_lease < now()));
$c$);

-- History logs: + the transcript's status
drop function if exists public.callyzer_logs(uuid, uuid, uuid, timestamptz, timestamptz);
create function public.callyzer_logs(p_tenant uuid, p_business uuid, p_sub uuid, p_from timestamptz, p_to timestamptz)
 returns table(id uuid, phone text, direction text, started_at timestamptz, duration_sec integer, call_method text, emp_name text, agent_phone text, recording_url text, recording_path text, lead_id uuid, lead_name text, transcript_status text)
 language sql stable security definer set search_path = ''
as $$
  select c.id, c.phone, c.direction, c.started_at, c.duration_sec, c.call_method, c.emp_name, c.agent_phone, c.recording_url, c.recording_path,
         l.id, nullif(btrim(concat_ws(' ', l.first_name, l.last_name)), ''), c.transcript_status
    from public.calls c
    left join lateral (
      select l.id, l.first_name, l.last_name from public.leads l
       where l.tenant_id = c.tenant_id and private.ph10(l.phone) = c.phone
         and (p_business is null or l.business_id = p_business)
         and (p_sub is null or l.sub_business_id = p_sub)
       order by l.created_at desc limit 1) l on true
   where c.tenant_id = p_tenant and c.source = 'callyzer'
     and c.started_at >= p_from and c.started_at <= p_to
     and (private.has_permission(p_tenant, 'call_logs', 'view') or private.has_permission(p_tenant, 'settings', 'edit'))
     and (p_business is null or l.id is not null)
   order by c.started_at desc
   limit 5000;
$$;
grant execute on function public.callyzer_logs(uuid, uuid, uuid, timestamptz, timestamptz) to authenticated;
