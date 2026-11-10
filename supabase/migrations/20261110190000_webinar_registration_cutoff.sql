-- Registration closes X minutes before a date starts (webinars.reg_close_minutes, default 15). At that moment the next
-- date (and its Zoom meeting) is made: new registrations, the date widget and the WhatsApp group link move to it, while
-- the common join link keeps opening the date that's on until it ends.
alter table public.webinars add column if not exists reg_close_minutes int not null default 15
  check (reg_close_minutes between 0 and 1440);

create or replace function private.webinar_ensure_next(p_webinar uuid, p_force boolean default false) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  w public.webinars;
  up public.events;
  last_d date;
  nd date;
  tid uuid;
  eid uuid;
  cut interval;
begin
  select * into w from public.webinars where id = p_webinar;
  if w.id is null or w.archived_at is not null then return null; end if;
  cut := make_interval(mins => coalesce(w.reg_close_minutes, 15));
  -- the date still open for registration (its start minus the cutoff is ahead)
  select * into up from public.events e
   where e.webinar_id = w.id and not e.is_cancelled and ((e.event_date + e.start_time) at time zone 'Asia/Kolkata') - cut > now()
   order by e.event_date, e.start_time limit 1;
  -- the latest date whose registration has closed (on now, or past)
  select max(e.event_date) into last_d from public.events e
   where e.webinar_id = w.id and not e.is_cancelled and ((e.event_date + e.start_time) at time zone 'Asia/Kolkata') - cut <= now();
  nd := private.webinar_next_date(w, last_d);

  if up.id is not null then
    if nd is null then
      update public.events set is_cancelled = true where id = up.id;
      return null;
    end if;
    update public.events
       set event_date = nd, start_time = w.start_time, end_time = w.end_time, title = w.title, description = w.description,
           zoom_account_id = w.zoom_account_id, zoom_kind = 'meeting', business_id = w.business_id
     where id = up.id
       and (event_date, start_time, end_time, title, coalesce(description, ''), zoom_account_id, business_id)
           is distinct from (nd, w.start_time, w.end_time, w.title, coalesce(w.description, ''), w.zoom_account_id, w.business_id);
    return up.id;
  end if;
  if not w.is_active or nd is null then return null; end if;

  select id into tid from public.event_types where tenant_id = w.tenant_id and kind = 'webinar' order by is_active desc, sort_order limit 1;
  if tid is null then
    insert into public.event_types (tenant_id, name, kind, color, sort_order) values (w.tenant_id, 'Webinar', 'webinar', '#8b5cf6', 1)
    returning id into tid;
  end if;
  insert into public.events (tenant_id, business_id, type_id, title, event_date, start_time, end_time, description,
                             zoom_account_id, zoom_kind, webinar_id, series_id, created_by)
  values (w.tenant_id, w.business_id, tid, w.title, nd, w.start_time, w.end_time, w.description,
          w.zoom_account_id, 'meeting', w.id, w.id, w.created_by)
  returning id into eid;
  return eid;
end $$;

/**
 * <app>/<link>: a webinar's join link → the Zoom link of the date that's on (until it ends), else the next one;
 * its WhatsApp group link → the group of the date open for registration (it moves at the cutoff, with the landing page).
 */
create or replace function public.webinar_link_open(p_tenant uuid, p_slug text)
returns text language plpgsql stable security definer set search_path = '' as $$
declare
  w public.webinars;
  v text;
  d date;
  cut interval;
begin
  select * into w from public.webinars
   where tenant_id = p_tenant and archived_at is null and (slug = lower(p_slug) or wa_slug = lower(p_slug)) limit 1;
  if w.id is null then return null; end if;
  if w.slug = lower(p_slug) then
    select e.meeting_link into v from public.events e
     where e.webinar_id = w.id and not e.is_cancelled
       and ((e.event_date + coalesce(e.end_time, e.start_time)) at time zone 'Asia/Kolkata') > now()
     order by e.event_date, e.start_time limit 1;
    return v;
  end if;
  cut := make_interval(mins => coalesce(w.reg_close_minutes, 15));
  -- the date open for registration (made); not made yet (a minute after the cutoff): the first date after the closed ones
  select e.event_date into d from public.events e
   where e.webinar_id = w.id and not e.is_cancelled and ((e.event_date + e.start_time) at time zone 'Asia/Kolkata') - cut > now()
   order by e.event_date, e.start_time limit 1;
  if d is null then
    select g.invite_link into v from public.webinar_groups g
     where g.webinar_id = w.id and g.group_date >= (now() at time zone 'Asia/Kolkata')::date
       and g.group_date > coalesce((select max(e.event_date) from public.events e where e.webinar_id = w.id and not e.is_cancelled
                                     and ((e.event_date + e.start_time) at time zone 'Asia/Kolkata') - cut <= now()), '-infinity'::date)
     order by g.group_date limit 1;
    return v;
  end if;
  select g.invite_link into v from public.webinar_groups g where g.webinar_id = w.id and g.group_date = d;
  return v;
end $$;
revoke all on function public.webinar_link_open(uuid, text) from public;
grant execute on function public.webinar_link_open(uuid, text) to anon, authenticated;

/** the date widget: the webinar's date open for registration (it moves at the cutoff) */
create or replace function public.webinar_widget(p_code text)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
           'title', e.title,
           'date', e.event_date,
           'time', to_char(e.start_time, 'HH24:MI'),
           'end_time', to_char(coalesce(e.end_time, e.start_time), 'HH24:MI'),
           'start', to_char(((e.event_date + e.start_time) at time zone 'Asia/Kolkata') at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
           'end', to_char(((e.event_date + coalesce(e.end_time, e.start_time)) at time zone 'Asia/Kolkata') at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
           -- when it stops being this one (the cutoff), so the page fetches the next
           'switch', to_char((((e.event_date + e.start_time) at time zone 'Asia/Kolkata') - make_interval(mins => coalesce(w.reg_close_minutes, 15))) at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'))
  from public.widgets wd
  join public.webinars w on w.id = nullif(wd.config ->> 'webinar_id', '')::uuid and w.archived_at is null
  join public.events e on e.webinar_id = w.id and not e.is_cancelled
  where wd.code = p_code and wd.kind = 'webinar_date' and wd.is_active and wd.archived_at is null
    and ((e.event_date + e.start_time) at time zone 'Asia/Kolkata') - make_interval(mins => coalesce(w.reg_close_minutes, 15)) > now()
  order by e.event_date, e.start_time
  limit 1
$$;
revoke all on function public.webinar_widget(text) from public;
grant execute on function public.webinar_widget(text) to anon, authenticated;
