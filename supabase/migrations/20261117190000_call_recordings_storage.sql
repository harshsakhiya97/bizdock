-- Our own copy of every Callyzer call recording: bucket call-recordings (private), path <tenant>/<yyyy>/<mm>/<call id>.mp3.
-- The recording-copy edge function (cron every minute while any is waiting) downloads Callyzer's mp3, uploads it and saves
-- recording_path on callyzer_team_calls and on the matching public.calls row. The Callyzer link stays as a backup.
insert into storage.buckets (id, name, public) values ('call-recordings', 'call-recordings', false) on conflict (id) do nothing;

create policy "call-recordings: read" on storage.objects for select to authenticated
  using (bucket_id = 'call-recordings'
         and (private.has_permission(((storage.foldername(name))[1])::uuid, 'call_logs', 'view')
              or private.has_permission(((storage.foldername(name))[1])::uuid, 'settings', 'edit')));

alter table public.callyzer_team_calls
  add column recording_path text,
  add column copy_tries int not null default 0,
  add column copy_error text;
alter table public.calls add column recording_path text;
create index callyzer_team_calls_to_copy on public.callyzer_team_calls (started_at desc)
  where recording_url is not null and recording_path is null and copy_tries < 5;

create or replace function private.kick_recording_copy()
returns void language sql security definer set search_path to '' as $$
  select net.http_post(
    url := 'https://tnnjudehqalkgglzkfik.supabase.co/functions/v1/recording-copy',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-secret', public.workflow_cron_secret()),
    body := '{"action":"cron"}'::jsonb,
    timeout_milliseconds := 55000
  );
$$;

select cron.schedule('recording-copy', '* * * * *', $cron$
  select private.kick_recording_copy()
  where exists (select 1 from public.callyzer_team_calls where recording_url is not null and recording_path is null and copy_tries < 5);
$cron$);

-- the Team numbers call list also returns our copy's path
drop function public.callyzer_team_calls_of(uuid, text, timestamptz, timestamptz);
create function public.callyzer_team_calls_of(p_tenant uuid, p_emp text, p_from timestamptz, p_to timestamptz)
returns table (external_id text, started_at timestamptz, client_number text, call_type text, call_method text, call_mode text,
               duration_sec int, recording_url text, recording_path text, lead_id uuid, lead_name text)
language sql stable security definer set search_path to '' as $$
  select c.external_id, c.started_at, c.client_number, c.call_type, c.call_method, c.call_mode, c.duration_sec, c.recording_url, c.recording_path,
         l.id, nullif(trim(concat_ws(' ', l.first_name, l.last_name)), '')
    from public.callyzer_team_calls c
    left join lateral (
      select x.id, x.first_name, x.last_name from public.leads x
       where x.tenant_id = p_tenant and c.client_number is not null
         and right(regexp_replace(coalesce(x.phone, ''), '\D', '', 'g'), 10) = c.client_number
       order by x.created_at desc limit 1) l on true
   where c.tenant_id = p_tenant and c.emp_number = p_emp and c.started_at >= p_from and c.started_at < p_to
     and (private.has_permission(p_tenant, 'call_logs', 'view') or private.has_permission(p_tenant, 'settings', 'edit'))
   order by c.started_at desc
$$;
revoke all on function public.callyzer_team_calls_of(uuid, text, timestamptz, timestamptz) from public, anon;
grant execute on function public.callyzer_team_calls_of(uuid, text, timestamptz, timestamptz) to authenticated;

-- History logs also return our copy's path
drop function public.callyzer_logs(uuid, uuid, uuid, timestamptz, timestamptz);
create function public.callyzer_logs(p_tenant uuid, p_business uuid, p_sub uuid, p_from timestamptz, p_to timestamptz)
 returns table(id uuid, phone text, direction text, started_at timestamptz, duration_sec integer, call_method text, emp_name text, agent_phone text, recording_url text, recording_path text, lead_id uuid, lead_name text)
 language sql stable security definer set search_path to ''
as $function$
  select c.id, c.phone, c.direction, c.started_at, c.duration_sec, c.call_method, c.emp_name, c.agent_phone, c.recording_url, c.recording_path,
         l.id, nullif(btrim(concat_ws(' ', l.first_name, l.last_name)), '')
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
$function$;
revoke all on function public.callyzer_logs(uuid, uuid, uuid, timestamptz, timestamptz) from public, anon;
grant execute on function public.callyzer_logs(uuid, uuid, uuid, timestamptz, timestamptz) to authenticated;
