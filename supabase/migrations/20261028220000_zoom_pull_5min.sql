-- Zoom attendance is pulled 5 minutes after the end (cron every 5 minutes); while Zoom's report isn't
-- ready the first pull is tried again each run for up to 2 hours (zoom function). Chat pass after 4 hours.
create or replace function public.zoom_due(p_limit int default 10)
returns table (kind text, id uuid)
language sql stable security definer set search_path = '' as $$
  (select 'meeting', m.id from public.meetings m
   where m.zoom_meeting_id is not null and m.zoom_account_id is not null and m.status <> 'cancelled'
     and ((m.meeting_date + m.end_time) at time zone 'Asia/Kolkata') > now() - interval '3 days'
     and ((m.zoom_pull_count = 0 and ((m.meeting_date + m.end_time) at time zone 'Asia/Kolkata') < now() - interval '5 minutes')
       or (m.zoom_pull_count = 1 and ((m.meeting_date + m.end_time) at time zone 'Asia/Kolkata') < now() - interval '4 hours'))
   limit p_limit)
  union all
  (select 'event', e.id from public.events e
   where e.zoom_webinar_id is not null and e.zoom_account_id is not null and not e.is_cancelled
     and ((coalesce(e.end_date, e.event_date) + coalesce(e.end_time, e.start_time, time '23:00')) at time zone 'Asia/Kolkata') > now() - interval '3 days'
     and ((e.zoom_pull_count = 0 and ((coalesce(e.end_date, e.event_date) + coalesce(e.end_time, e.start_time, time '23:00')) at time zone 'Asia/Kolkata') < now() - interval '5 minutes')
       or (e.zoom_pull_count = 1 and ((coalesce(e.end_date, e.event_date) + coalesce(e.end_time, e.start_time, time '23:00')) at time zone 'Asia/Kolkata') < now() - interval '4 hours'))
   limit p_limit)
$$;
revoke all on function public.zoom_due(int) from public, anon, authenticated;
grant execute on function public.zoom_due(int) to service_role;
select cron.unschedule('zoom-pull');
select cron.schedule('zoom-pull', '*/5 * * * *', $job$
  select private.kick_zoom('{"action":"cron"}'::jsonb) where exists (select 1 from public.zoom_due(1));
$job$);
