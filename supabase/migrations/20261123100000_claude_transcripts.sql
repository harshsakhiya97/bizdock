-- Claude API connection + Sync transcripts (Callyzer → History logs).
--   provider 'claude' (API key + model); Pride may use it.
--   transcript_syncs: a workspace's Sync transcripts run — while active, the worker (call-transcribe, every minute)
--     fixes the old transcripts' speaker labels with Claude (calls.transcript_redo, written before 21 Nov 15:00 UTC)
--     and writes the missing ones with Gemini; it ends itself when nothing is left.
--   New calls: written by Gemini automatically within a minute of their recording being copied (last 3 days).
alter table public.integrations drop constraint if exists integrations_provider_check;
alter table public.integrations add constraint integrations_provider_check
  check (provider = any (array['whatsapp','callyzer','zoom','voice_call','perisclaw','facebook_ads','razorpay','google_ads','gemini','hellorix','claude']));
update public.tenants set connections = connections || '{"claude":{"allowed":true}}'::jsonb where id = 'cfdf9009-0f78-4041-83c1-1975ce98e234';

create table if not exists public.transcript_syncs (
  tenant_id uuid primary key references public.tenants(id) on delete cascade,
  active boolean not null default false,
  started_at timestamptz,
  started_by uuid,
  finished_at timestamptz,
  relabel_total integer not null default 0,
  write_total integer not null default 0,
  note text
);
alter table public.transcript_syncs enable row level security;
create policy "transcript_syncs: read" on public.transcript_syncs for select to authenticated
  using (private.has_permission(tenant_id, 'call_logs', 'view') or private.has_permission(tenant_id, 'settings', 'edit'));
grant select on public.transcript_syncs to authenticated;

-- the calls to work on: 'auto' = new calls (last 3 days) with no transcript; 'write' = every call with no transcript;
-- 'relabel' = old transcripts to fix (Claude). Held for 3 minutes. p_tenant null = every workspace.
drop function if exists public.call_transcript_claim(integer);
create or replace function public.call_transcript_claim(p_limit integer default 5, p_mode text default 'auto', p_tenant uuid default null) returns setof uuid
language sql volatile security definer set search_path = '' as $$
  update public.calls set transcript_lease = now() + interval '3 minutes'
  where id in (
    select id from public.calls
    where source = 'callyzer' and recording_path is not null and coalesce(duration_sec, 0) >= 5
      and (p_tenant is null or tenant_id = p_tenant)
      and transcript_tries < 3
      and (transcript_lease is null or transcript_lease < now())
      and case p_mode
            when 'relabel' then transcript_status = 'done' and transcript_redo and transcript_at < timestamptz '2026-11-21 15:00:00+00'
            when 'write' then transcript_status is null or transcript_status = 'waiting'
            else (transcript_status is null or transcript_status = 'waiting') and started_at > now() - interval '3 days'
          end
    order by started_at desc
    limit p_limit
    for update skip locked
  )
  returning id
$$;
revoke all on function public.call_transcript_claim(integer, text, uuid) from public, anon, authenticated;

-- what Sync transcripts would do / is doing
create or replace function public.transcript_sync_status(p_tenant uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select case when private.has_permission(p_tenant, 'call_logs', 'view') or private.has_permission(p_tenant, 'settings', 'edit') then
    jsonb_build_object(
      'relabel_left', (select count(*) from public.calls where tenant_id = p_tenant and source = 'callyzer' and recording_path is not null and coalesce(duration_sec, 0) >= 5
                        and transcript_status = 'done' and transcript_redo and transcript_at < timestamptz '2026-11-21 15:00:00+00' and transcript_tries < 3),
      'write_left', (select count(*) from public.calls where tenant_id = p_tenant and source = 'callyzer' and recording_path is not null and coalesce(duration_sec, 0) >= 5
                        and (transcript_status is null or transcript_status = 'waiting') and transcript_tries < 3),
      'failed', (select count(*) from public.calls where tenant_id = p_tenant and source = 'callyzer' and transcript_status = 'error'),
      'claude', exists (select 1 from public.integrations where tenant_id = p_tenant and provider = 'claude' and is_enabled and coalesce(config->>'api_key', '') <> ''),
      'gemini', exists (select 1 from public.integrations where tenant_id = p_tenant and provider = 'gemini' and is_enabled and coalesce(config->>'api_key', '') <> ''),
      'sync', (select to_jsonb(s) - 'tenant_id' from public.transcript_syncs s where s.tenant_id = p_tenant)
    )
  end
$$;
grant execute on function public.transcript_sync_status(uuid) to authenticated;

-- start / stop Sync transcripts
create or replace function public.transcript_sync_set(p_tenant uuid, p_on boolean) returns void
language plpgsql volatile security definer set search_path = '' as $$
declare st jsonb;
begin
  if not (private.has_permission(p_tenant, 'call_logs', 'view') or private.has_permission(p_tenant, 'settings', 'edit')) then
    raise exception 'Not allowed';
  end if;
  if p_on then
    st := public.transcript_sync_status(p_tenant);
    insert into public.transcript_syncs (tenant_id, active, started_at, started_by, finished_at, relabel_total, write_total, note)
    values (p_tenant, true, now(), auth.uid(), null, case when (st->>'claude')::boolean then (st->>'relabel_left')::int else 0 end, (st->>'write_left')::int, null)
    on conflict (tenant_id) do update set active = true, started_at = now(), started_by = auth.uid(), finished_at = null,
      relabel_total = excluded.relabel_total, write_total = excluded.write_total, note = null;
  else
    update public.transcript_syncs set active = false, finished_at = now(), note = 'Stopped' where tenant_id = p_tenant;
  end if;
end $$;
grant execute on function public.transcript_sync_set(uuid, boolean) to authenticated;

-- the worker: every minute while a new call waits or a sync is on
select cron.unschedule('call-transcribe') where exists (select 1 from cron.job where jobname = 'call-transcribe');
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
  where exists (select 1 from public.transcript_syncs where active)
     or exists (select 1 from public.calls
                where source = 'callyzer' and recording_path is not null and coalesce(duration_sec, 0) >= 5
                  and (transcript_status is null or transcript_status = 'waiting') and transcript_tries < 3
                  and started_at > now() - interval '3 days'
                  and (transcript_lease is null or transcript_lease < now()));
$c$);
