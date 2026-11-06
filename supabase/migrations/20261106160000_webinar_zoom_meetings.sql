-- A webinar's dates are made as Zoom MEETINGS (registration required), not Zoom webinars:
-- the app still calls them webinars.
create or replace function private.webinar_ensure_next(p_webinar uuid, p_force boolean default false) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  w public.webinars;
  up public.events;
  last_d date;
  live boolean;
  nd date;
  tid uuid;
  eid uuid;
begin
  select * into w from public.webinars where id = p_webinar;
  if w.id is null or w.archived_at is not null then return null; end if;
  select * into up from public.events e
   where e.webinar_id = w.id and not e.is_cancelled and ((e.event_date + e.start_time) at time zone 'Asia/Kolkata') > now()
   order by e.event_date, e.start_time limit 1;
  select max(e.event_date) into last_d from public.events e
   where e.webinar_id = w.id and not e.is_cancelled and ((e.event_date + e.start_time) at time zone 'Asia/Kolkata') <= now();
  live := exists (select 1 from public.events e
   where e.webinar_id = w.id and not e.is_cancelled
     and ((e.event_date + e.start_time) at time zone 'Asia/Kolkata') <= now()
     and ((e.event_date + coalesce(e.end_time, e.start_time)) at time zone 'Asia/Kolkata') > now());
  nd := private.webinar_next_date(w, last_d);

  if up.id is not null then
    if nd is null then
      -- the webinar no longer has this date (e.g. the stop date moved): call it off
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
  if live and not p_force then return null; end if;

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
