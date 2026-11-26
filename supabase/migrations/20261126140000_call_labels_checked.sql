-- Callyzer transcripts: Claude checks the Team / Customer labels of every transcript (Gemini flash-lite flips the
-- speakers). labels_checked = done; Sync transcripts checks every transcript not checked yet ('relabel').
alter table public.calls add column if not exists labels_checked boolean not null default false;
create or replace function public.call_transcript_claim(p_limit integer default 5, p_mode text default 'auto', p_tenant uuid default null)
returns setof uuid
language sql security definer set search_path = '' as $$
  update public.calls set transcript_lease = now() + interval '3 minutes'
  where id in (
    select id from public.calls
    where source = 'callyzer' and recording_path is not null and coalesce(duration_sec, 0) >= 5
      and (p_tenant is null or tenant_id = p_tenant)
      and transcript_tries < 3
      and (transcript_lease is null or transcript_lease < now())
      and case p_mode
            when 'relabel' then transcript_status = 'done' and not labels_checked and transcript ~ '^(Team|Customer)'
            when 'write' then transcript_status is null or transcript_status = 'waiting'
            else (transcript_status is null or transcript_status = 'waiting') and started_at > now() - interval '3 days'
          end
    order by started_at desc
    limit p_limit
    for update skip locked
  )
  returning id
$$;
create or replace function public.transcript_sync_status(p_tenant uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select case when private.has_permission(p_tenant, 'call_logs', 'view') or private.has_permission(p_tenant, 'settings', 'edit') then
    jsonb_build_object(
      'relabel_left', (select count(*) from public.calls where tenant_id = p_tenant and source = 'callyzer' and recording_path is not null and coalesce(duration_sec, 0) >= 5
                        and transcript_status = 'done' and not labels_checked and transcript ~ '^(Team|Customer)' and transcript_tries < 3),
      'write_left', (select count(*) from public.calls where tenant_id = p_tenant and source = 'callyzer' and recording_path is not null and coalesce(duration_sec, 0) >= 5
                        and (transcript_status is null or transcript_status = 'waiting') and transcript_tries < 3),
      'failed', (select count(*) from public.calls where tenant_id = p_tenant and source = 'callyzer' and transcript_status = 'error'),
      'claude', exists (select 1 from public.integrations where tenant_id = p_tenant and provider = 'claude' and is_enabled and coalesce(config->>'api_key', '') <> ''),
      'gemini', exists (select 1 from public.integrations where tenant_id = p_tenant and provider = 'gemini' and is_enabled and coalesce(config->>'api_key', '') <> ''),
      'sync', (select to_jsonb(s) - 'tenant_id' from public.transcript_syncs s where s.tenant_id = p_tenant)
    )
  end
$$;
