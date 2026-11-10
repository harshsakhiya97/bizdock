-- Widgets → Webinar date & time: a widget tied to a webinar; its script shows the webinar's current date (on now, else
-- the next one) on any page — date, time, time with IST, or a countdown.
alter table public.widgets drop constraint if exists widgets_kind_check;
alter table public.widgets add constraint widgets_kind_check check (kind in ('booking_calendar', 'webinar_date'));

/** the embed's current webinar date (public): { title, date, time, end_time, start, end } in India time, or null */
create or replace function public.webinar_widget(p_code text)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
           'title', e.title,
           'date', e.event_date,
           'time', to_char(e.start_time, 'HH24:MI'),
           'end_time', to_char(coalesce(e.end_time, e.start_time), 'HH24:MI'),
           'start', to_char(((e.event_date + e.start_time) at time zone 'Asia/Kolkata') at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
           'end', to_char(((e.event_date + coalesce(e.end_time, e.start_time)) at time zone 'Asia/Kolkata') at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'))
  from public.widgets wd
  join public.webinars w on w.id = nullif(wd.config ->> 'webinar_id', '')::uuid and w.archived_at is null
  join public.events e on e.webinar_id = w.id and not e.is_cancelled
  where wd.code = p_code and wd.kind = 'webinar_date' and wd.is_active and wd.archived_at is null
    and ((e.event_date + coalesce(e.end_time, e.start_time)) at time zone 'Asia/Kolkata') > now()
  order by e.event_date, e.start_time
  limit 1
$$;
revoke all on function public.webinar_widget(text) from public;
grant execute on function public.webinar_widget(text) to anon, authenticated;
