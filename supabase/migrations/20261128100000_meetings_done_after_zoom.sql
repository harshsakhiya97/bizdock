-- A Zoom meeting turns Done by itself 5 minutes after its end (its attendance, Q&A and recording are fetched then too,
-- by the zoom-pull / zoom-recordings jobs). Checked every 5 minutes; a cancelled / no-show one is left alone.
create or replace function private.meetings_done_after_end() returns void
language sql security definer set search_path = '' as $$
  update public.meetings set status = 'done'
   where status = 'scheduled' and zoom_meeting_id is not null
     and ((meeting_date + coalesce(end_time, start_time, time '23:59')) at time zone 'Asia/Kolkata') <= now() - interval '5 minutes'
$$;
select cron.schedule('meetings-done', '*/5 * * * *', 'select private.meetings_done_after_end()');
select private.meetings_done_after_end();
