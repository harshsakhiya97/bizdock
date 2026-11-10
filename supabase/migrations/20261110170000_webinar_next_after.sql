-- The webinar's next date after a given date (workflows' "Next webinar" fields): a date already made, else the next one
-- by its repeat (not made yet). Null when there's none.
create or replace function public.webinar_next_after(p_event uuid)
returns table (event_date date, start_time time, end_time time, title text)
language plpgsql stable security definer set search_path = '' as $$
declare
  ev public.events;
  w public.webinars;
  d date;
begin
  select * into ev from public.events where id = p_event;
  if ev.id is null or ev.webinar_id is null then return; end if;
  select * into w from public.webinars where id = ev.webinar_id;
  return query
    select e.event_date, e.start_time, e.end_time, e.title from public.events e
     where e.webinar_id = ev.webinar_id and not e.is_cancelled and e.id <> ev.id
       and (e.event_date, e.start_time) > (ev.event_date, ev.start_time)
     order by e.event_date, e.start_time limit 1;
  if found then return; end if;
  if w.id is null or w.archived_at is not null then return; end if;
  d := private.webinar_next_date(w, ev.event_date);
  if d is not null then
    return query select d, w.start_time, w.end_time, w.title;
  end if;
end $$;
revoke all on function public.webinar_next_after(uuid) from public, anon, authenticated;
grant execute on function public.webinar_next_after(uuid) to service_role;
