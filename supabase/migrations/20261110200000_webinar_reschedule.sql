-- Reschedule a webinar date (only this date, or — weekly — this and all future dates), and delete a date while moving
-- its registered leads to the next date (they go through the registration workflow again). Optional WhatsApp message to
-- the registrants (rescheduled / cancelled), sent by the workflow runner from webinar_notices.

-- a date moved on its own: [{from, date, start, end}] — made like the repeat's own dates (its rule date is in skipped_dates)
alter table public.webinars add column if not exists moved_dates jsonb not null default '[]'::jsonb;
-- a registration moved to the next date when its date was deleted
alter table public.webinar_registrations add column if not exists moved_to_event uuid;
alter table public.webinar_registrations add column if not exists moved_to_date date;

create table if not exists public.webinar_notices (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  webinar_id uuid references public.webinars(id) on delete cascade,
  -- the date whose "Webinar fields" the message uses (rescheduled: its new date; cancelled: the cancelled one, with "Next webinar")
  event_id uuid not null references public.events(id) on delete cascade,
  lead_id uuid not null references public.leads(id) on delete cascade,
  kind text not null check (kind in ('reschedule', 'cancel')),
  template text not null,
  template_body text,
  params jsonb not null default '{}'::jsonb,
  status text not null default 'queued' check (status in ('queued', 'sending', 'sent', 'failed')),
  error text,
  created_by uuid references public.tenant_members(id) on delete set null,
  created_at timestamptz not null default now(),
  claimed_at timestamptz,
  sent_at timestamptz
);
create index if not exists webinar_notices_queued on public.webinar_notices (created_at) where status = 'queued';
alter table public.webinar_notices enable row level security;
drop policy if exists "webinar_notices: read" on public.webinar_notices;
create policy "webinar_notices: read" on public.webinar_notices for select to authenticated using (private.is_member(tenant_id));

-- the repeat's own next date (weekly days / its dates / the one date), without the deleted and moved ones
create or replace function private.webinar_rule_date(w public.webinars, p_after date) returns date
language plpgsql stable set search_path = '' as $$
declare
  d date;
  today date := (now() at time zone 'Asia/Kolkata')::date;
  skip date[] := coalesce(w.skipped_dates, '{}');
begin
  if w.repeat = 'once' then
    if p_after is not null and w.first_date <= p_after then return null; end if;
    if w.first_date = any (skip) then return null; end if;
    if ((w.first_date + w.start_time) at time zone 'Asia/Kolkata') <= now() then return null; end if;
    return w.first_date;
  elsif w.repeat = 'dates' then
    select min(x) into d from unnest(w.dates) x
     where (p_after is null or x > p_after) and not (x = any (skip)) and ((x + w.start_time) at time zone 'Asia/Kolkata') > now();
    return d;
  end if;
  if coalesce(array_length(w.weekdays, 1), 0) = 0 then return null; end if;
  d := greatest(w.first_date, coalesce(p_after + 1, w.first_date), today);
  for i in 0..21 loop
    if w.stop_date is not null and d > w.stop_date then return null; end if;
    if extract(dow from d)::int = any (w.weekdays) and not (d = any (skip)) and ((d + w.start_time) at time zone 'Asia/Kolkata') > now() then return d; end if;
    d := d + 1;
  end loop;
  return null;
end $$;

-- the webinar's next date after p_after with its times: the repeat's own (webinar times) or a moved one (its own times)
create or replace function private.webinar_next_slot(w public.webinars, p_after date, out d date, out st time, out et time)
language plpgsql stable set search_path = '' as $$
declare
  r date;
  md date;
  ms time;
  me time;
begin
  r := private.webinar_rule_date(w, p_after);
  if w.repeat <> 'once' then
    select (x ->> 'date')::date, (x ->> 'start')::time, (x ->> 'end')::time into md, ms, me
      from jsonb_array_elements(coalesce(w.moved_dates, '[]'::jsonb)) t(x)
     where (p_after is null or (x ->> 'date')::date > p_after)
       and (w.repeat <> 'weekly' or w.stop_date is null or (x ->> 'date')::date <= w.stop_date)
       and (((x ->> 'date')::date + (x ->> 'start')::time) at time zone 'Asia/Kolkata') > now()
     order by 1, 2 limit 1;
  end if;
  if md is not null and (r is null or md <= r) then
    d := md; st := ms; et := me;
  elsif r is not null then
    d := r; st := w.start_time; et := w.end_time;
  end if;
end $$;

-- kept for its callers: the next date only
create or replace function private.webinar_next_date(w public.webinars, p_after date) returns date
language sql stable set search_path = '' as $$
  select (private.webinar_next_slot(w, p_after)).d
$$;

-- as before, with a moved date's own times
create or replace function private.webinar_ensure_next(p_webinar uuid, p_force boolean default false) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  w public.webinars;
  up public.events;
  last_d date;
  s record;
  tid uuid;
  eid uuid;
  cut interval;
begin
  select * into w from public.webinars where id = p_webinar;
  if w.id is null or w.archived_at is not null then return null; end if;
  cut := make_interval(mins => coalesce(w.reg_close_minutes, 15));
  select * into up from public.events e
   where e.webinar_id = w.id and not e.is_cancelled and ((e.event_date + e.start_time) at time zone 'Asia/Kolkata') - cut > now()
   order by e.event_date, e.start_time limit 1;
  select max(e.event_date) into last_d from public.events e
   where e.webinar_id = w.id and not e.is_cancelled and ((e.event_date + e.start_time) at time zone 'Asia/Kolkata') - cut <= now();
  select * into s from private.webinar_next_slot(w, last_d);

  if up.id is not null then
    if s.d is null then
      update public.events set is_cancelled = true where id = up.id;
      return null;
    end if;
    update public.events
       set event_date = s.d, start_time = s.st, end_time = s.et, title = w.title, description = w.description,
           zoom_account_id = w.zoom_account_id, zoom_kind = 'meeting', business_id = w.business_id
     where id = up.id
       and (event_date, start_time, end_time, title, coalesce(description, ''), zoom_account_id, business_id)
           is distinct from (s.d, s.st, s.et, w.title, coalesce(w.description, ''), w.zoom_account_id, w.business_id);
    return up.id;
  end if;
  if not w.is_active or s.d is null then return null; end if;

  select id into tid from public.event_types where tenant_id = w.tenant_id and kind = 'webinar' order by is_active desc, sort_order limit 1;
  if tid is null then
    insert into public.event_types (tenant_id, name, kind, color, sort_order) values (w.tenant_id, 'Webinar', 'webinar', '#8b5cf6', 1)
    returning id into tid;
  end if;
  insert into public.events (tenant_id, business_id, type_id, title, event_date, start_time, end_time, description,
                             zoom_account_id, zoom_kind, webinar_id, series_id, created_by)
  values (w.tenant_id, w.business_id, tid, w.title, s.d, s.st, s.et, w.description,
          w.zoom_account_id, 'meeting', w.id, w.id, w.created_by)
  returning id into eid;
  return eid;
end $$;

-- "Next webinar" fields: with a moved date's own times
create or replace function public.webinar_next_after(p_event uuid)
returns table (event_date date, start_time time, end_time time, title text)
language plpgsql stable security definer set search_path = '' as $$
declare
  ev public.events;
  w public.webinars;
  s record;
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
  select * into s from private.webinar_next_slot(w, ev.event_date);
  if s.d is not null then
    return query select s.d, s.st, s.et, w.title;
  end if;
end $$;
revoke all on function public.webinar_next_after(uuid) from public, anon, authenticated;
grant execute on function public.webinar_next_after(uuid) to service_role;

-- the dates (made or scheduled) right before and right after a date of the webinar
create or replace function private.webinar_neighbours(w public.webinars, p_date date, out prev date, out nxt date)
language plpgsql stable set search_path = '' as $$
declare
  cur date;
  s record;
begin
  select max(e.event_date) into prev from public.events e where e.webinar_id = w.id and not e.is_cancelled and e.event_date < p_date;
  cur := prev;
  for i in 1..400 loop
    select * into s from private.webinar_next_slot(w, cur);
    exit when s.d is null or s.d >= p_date;
    prev := s.d;
    cur := s.d;
  end loop;
  select min(e.event_date) into nxt from public.events e where e.webinar_id = w.id and not e.is_cancelled and e.event_date > p_date;
  select * into s from private.webinar_next_slot(w, p_date);
  nxt := least(nxt, s.d);
end $$;

/**
 * Reschedule one date of a webinar (made, or scheduled — not made yet) to a new date and time, between the dates before
 * and after it. p_scope 'one': only this date; 'future' (weekly): from this date on, the webinar repeats on the new day and
 * time. A made date keeps its Zoom meeting (moved), its registrations, its links and its WhatsApp group; its waiting
 * reminders are timed again. p_notice {template, template_body, params}: a WhatsApp to everyone registered for it.
 */
create or replace function public.webinar_reschedule(
  p_webinar uuid, p_from date, p_date date, p_start time, p_end time, p_scope text default 'one',
  p_notice jsonb default null, p_member uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  w public.webinars;
  ev public.events;
  nb record;
  s record;
  moved jsonb;
  kept jsonb;
  cur date;
  old_dow int;
  sent int := 0;
  fmt text := 'DD Mon YYYY';
begin
  select * into w from public.webinars where id = p_webinar and archived_at is null;
  if w.id is null then raise exception 'The webinar was deleted.'; end if;
  if not (private.has_permission(w.tenant_id, 'bookings', 'edit') or private.has_permission(w.tenant_id, 'bookings', 'add')) then
    raise exception 'You are not allowed to change webinars.';
  end if;
  if p_end <= p_start then raise exception 'The end time must be after the start time.'; end if;
  if ((p_date + p_start) at time zone 'Asia/Kolkata') <= now() then raise exception 'The new date and time must be in the future.'; end if;
  if p_scope not in ('one', 'future') or (p_scope = 'future' and w.repeat <> 'weekly') then p_scope := 'one'; end if;

  select * into ev from public.events e where e.webinar_id = w.id and not e.is_cancelled and e.event_date = p_from
   order by e.start_time limit 1;
  if ev.id is not null and ((ev.event_date + ev.start_time) at time zone 'Asia/Kolkata') <= now() then
    raise exception 'This date has already started.';
  end if;
  select * into nb from private.webinar_neighbours(w, p_from);
  if nb.prev is not null and p_date <= nb.prev then
    raise exception 'The new date must be after % (the date before it).', to_char(nb.prev, fmt);
  end if;
  if nb.nxt is not null and p_date >= nb.nxt then
    raise exception 'The new date must be before % (the next date).', to_char(nb.nxt, fmt);
  end if;

  -- the made date first (so the webinar's next date, worked out again below, is this one)
  if ev.id is not null then
    update public.events set event_date = p_date, start_time = p_start, end_time = p_end where id = ev.id;
    -- its WhatsApp group moves with it
    update public.webinar_groups g set group_date = p_date
     where g.webinar_id = w.id and g.group_date = p_from and p_date <> p_from
       and not exists (select 1 from public.webinar_groups x where x.webinar_id = w.id and x.group_date = p_date);
    -- reminders waiting for it: timed again from the new start
    update public.workflow_runs set next_at = now()
     where status = 'waiting' and (event_id = ev.id or state ->> 'event_id' = ev.id::text);
  else
    update public.webinar_groups g set group_date = p_date
     where g.webinar_id = w.id and g.group_date = p_from and p_date <> p_from
       and not exists (select 1 from public.webinar_groups x where x.webinar_id = w.id and x.group_date = p_date);
  end if;

  if w.repeat = 'once' then
    update public.webinars set first_date = p_date, start_time = p_start, end_time = p_end where id = w.id;
  elsif p_scope = 'one' then
    -- this date only: the repeat skips it, and it's made on the new date and time
    select coalesce(jsonb_agg(x), '[]'::jsonb) into kept
      from jsonb_array_elements(coalesce(w.moved_dates, '[]'::jsonb)) t(x) where (x ->> 'date')::date <> p_from;
    select x ->> 'from' into cur from jsonb_array_elements(coalesce(w.moved_dates, '[]'::jsonb)) t(x) where (x ->> 'date')::date = p_from limit 1;
    update public.webinars
       set skipped_dates = (select array_agg(distinct x order by x) from unnest(coalesce(skipped_dates, '{}') || p_from) x),
           moved_dates = kept || jsonb_build_array(jsonb_build_object('from', coalesce(cur, p_from), 'date', p_date,
                                                    'start', to_char(p_start, 'HH24:MI'), 'end', to_char(p_end, 'HH24:MI')))
     where id = w.id;
  else
    -- this and all future dates (weekly): the dates before it keep their day and time (kept as moved dates),
    -- and from the new date on the webinar repeats on its day and time
    moved := '[]'::jsonb;
    cur := null;
    for i in 1..400 loop
      select * into s from private.webinar_next_slot(w, cur);
      exit when s.d is null or s.d >= p_from;
      moved := moved || jsonb_build_array(jsonb_build_object('from', s.d, 'date', s.d, 'start', to_char(s.st, 'HH24:MI'), 'end', to_char(s.et, 'HH24:MI')));
      cur := s.d;
    end loop;
    select coalesce(jsonb_agg(x), '[]'::jsonb) into kept
      from jsonb_array_elements(coalesce(w.moved_dates, '[]'::jsonb)) t(x) where (x ->> 'date')::date > p_from;
    select coalesce((select (x ->> 'from')::date from jsonb_array_elements(coalesce(w.moved_dates, '[]'::jsonb)) t(x)
                      where (x ->> 'date')::date = p_from limit 1), p_from) into cur;
    old_dow := extract(dow from cur)::int;
    update public.webinars
       set weekdays = (select array_agg(distinct x order by x) from unnest(array_remove(weekdays, old_dow) || extract(dow from p_date)::int) x),
           first_date = p_date, start_time = p_start, end_time = p_end,
           moved_dates = moved || kept
     where id = w.id;
  end if;

  -- the message to everyone registered for it (not those moved away)
  if ev.id is not null and p_notice is not null and coalesce(p_notice ->> 'template', '') <> '' then
    insert into public.webinar_notices (tenant_id, webinar_id, event_id, lead_id, kind, template, template_body, params, created_by)
    select w.tenant_id, w.id, ev.id, r.lead_id, 'reschedule', p_notice ->> 'template', p_notice ->> 'template_body',
           coalesce(p_notice -> 'params', '{}'::jsonb), p_member
      from public.webinar_registrations r where r.event_id = ev.id and r.moved_to_event is null;
    get diagnostics sent = row_count;
    if sent > 0 then perform private.kick_workflow_runner(); end if;
  end if;
  return jsonb_build_object('event_id', ev.id, 'messages', sent);
end $$;
revoke all on function public.webinar_reschedule(uuid, date, date, time, time, text, jsonb, uuid) from public, anon;
grant execute on function public.webinar_reschedule(uuid, date, date, time, time, text, jsonb, uuid) to authenticated;

/**
 * Delete one made date. p_move: its registered leads go to the webinar's next date — their registration here is marked
 * moved, and the webinar's registration workflow runs for each (registered on the next date, with its confirmation and
 * reminders). p_notice {template, template_body, params}: first a WhatsApp to them (e.g. "cancelled, see you on …").
 */
create or replace function public.webinar_delete_date(p_event uuid, p_move boolean default false, p_notice jsonb default null, p_member uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  ev public.events;
  w public.webinars;
  wf uuid;
  nid uuid;
  nd date;
  moved int := 0;
  sent int := 0;
  notify boolean := p_notice is not null and coalesce(p_notice ->> 'template', '') <> '';
begin
  select * into ev from public.events where id = p_event and webinar_id is not null;
  if ev.id is null then raise exception 'The webinar date was not found.'; end if;
  select * into w from public.webinars where id = ev.webinar_id;
  if not (private.has_permission(ev.tenant_id, 'bookings', 'edit') or private.has_permission(ev.tenant_id, 'bookings', 'add')) then
    raise exception 'You are not allowed to change webinars.';
  end if;
  if p_move and ((ev.event_date + ev.start_time) at time zone 'Asia/Kolkata') <= now() then
    raise exception 'This date has already started: its leads can''t be moved.';
  end if;
  if p_move then
    select x.id into wf from public.workflows x
     where x.webinar_id = w.id and x.archived_at is null and x.is_active
       and exists (select 1 from jsonb_array_elements(x.nodes) t(n) where n ->> 'type' = 'register_webinar')
     order by x.created_at desc limit 1;
    if wf is null then raise exception 'The webinar''s registration workflow is off or deleted: turn it on to move the leads.'; end if;
  end if;

  update public.events set is_cancelled = true where id = ev.id;
  update public.webinars
     set skipped_dates = (select array_agg(distinct x order by x) from unnest(coalesce(skipped_dates, '{}') || ev.event_date) x),
         moved_dates = (select coalesce(jsonb_agg(x), '[]'::jsonb) from jsonb_array_elements(coalesce(moved_dates, '[]'::jsonb)) t(x)
                         where (x ->> 'date')::date <> ev.event_date)
   where id = w.id;
  -- its reminders and the rest of its runs stop
  update public.workflow_runs set status = 'stopped', error = 'The webinar date was deleted.', updated_at = now()
   where status in ('queued', 'waiting') and (event_id = ev.id or state ->> 'event_id' = ev.id::text);

  if p_move then
    nid := private.webinar_ensure_next(w.id, true);
    if nid is null then raise exception 'The webinar has no next date to move the leads to.'; end if;
    select event_date into nd from public.events where id = nid;
    update public.webinar_registrations set moved_to_event = nid, moved_to_date = nd
     where event_id = ev.id and moved_to_event is null;
    get diagnostics moved = row_count;
    if notify then
      insert into public.webinar_notices (tenant_id, webinar_id, event_id, lead_id, kind, template, template_body, params, created_by)
      select ev.tenant_id, w.id, ev.id, r.lead_id, 'cancel', p_notice ->> 'template', p_notice ->> 'template_body',
             coalesce(p_notice -> 'params', '{}'::jsonb), p_member
        from public.webinar_registrations r where r.event_id = ev.id and r.moved_to_event = nid;
      get diagnostics sent = row_count;
    end if;
    insert into public.lead_activities (tenant_id, lead_id, kind, note)
    select ev.tenant_id, r.lead_id, 'note',
           format('The webinar “%s” on %s was cancelled: moved to %s', ev.title, to_char(ev.event_date, 'DD Mon YYYY'), to_char(nd, 'DD Mon YYYY'))
      from public.webinar_registrations r where r.event_id = ev.id and r.moved_to_event = nid;
    -- the registration workflow for each (after the cancel message, so it arrives first)
    insert into public.workflow_runs (tenant_id, workflow_id, lead_id, next_at)
    select ev.tenant_id, wf, r.lead_id, now() + case when sent > 0 then interval '1 minute' else interval '0' end
      from public.webinar_registrations r where r.event_id = ev.id and r.moved_to_event = nid;
  elsif notify then
    insert into public.webinar_notices (tenant_id, webinar_id, event_id, lead_id, kind, template, template_body, params, created_by)
    select ev.tenant_id, w.id, ev.id, r.lead_id, 'cancel', p_notice ->> 'template', p_notice ->> 'template_body',
           coalesce(p_notice -> 'params', '{}'::jsonb), p_member
      from public.webinar_registrations r where r.event_id = ev.id and r.moved_to_event is null;
    get diagnostics sent = row_count;
  end if;
  if moved > 0 or sent > 0 then perform private.kick_workflow_runner(); end if;
  return jsonb_build_object('moved', moved, 'messages', sent, 'next_date', nd);
end $$;
revoke all on function public.webinar_delete_date(uuid, boolean, jsonb, uuid) from public, anon;
grant execute on function public.webinar_delete_date(uuid, boolean, jsonb, uuid) to authenticated;

-- the workflow runner takes the queued messages
create or replace function public.webinar_claim_notices(p_limit int default 50)
returns setof public.webinar_notices language sql security definer set search_path = '' as $$
  update public.webinar_notices n set status = 'sending', claimed_at = now()
   where n.id in (select id from public.webinar_notices where status = 'queued' order by created_at limit p_limit for update skip locked)
  returning n.*;
$$;
revoke all on function public.webinar_claim_notices(int) from public, anon, authenticated;
grant execute on function public.webinar_claim_notices(int) to service_role;

-- the runner is called when messages are waiting too
select cron.unschedule('workflow-runner');
select cron.schedule('workflow-runner', '10 seconds', $job$
  select private.start_webinar_workflows();
  update public.workflow_runs set status = 'queued' where status = 'running' and updated_at < now() - interval '10 minutes';
  update public.webinar_notices set status = 'queued' where status = 'sending' and claimed_at < now() - interval '15 minutes';
  select private.kick_workflow_runner()
  where exists (select 1 from public.workflow_runs where status in ('queued', 'waiting') and next_at <= now())
     or exists (select 1 from public.webinar_notices where status = 'queued');
$job$);
