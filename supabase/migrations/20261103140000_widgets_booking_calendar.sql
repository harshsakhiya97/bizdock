-- Widgets module: Booking Calendar widgets (an embeddable calendar of free slots) and the slots they hold.
create table public.widgets (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  kind text not null default 'booking_calendar' check (kind in ('booking_calendar')),
  name text not null,
  -- the public embed address: <app>/embed/<code>
  code text not null unique default substr(md5(gen_random_uuid()::text), 1, 10),
  is_active boolean not null default true,
  -- { interval, days: { mon: { on, start, end } … }, members: [member id], color, days_ahead, notice_hours,
  --   webhook: { type: 'workflow' | 'url', workflow_id?, url? }, thank_you, redirect_url }
  config jsonb not null default '{}'::jsonb,
  -- round robin: who got the last booking
  last_member_id uuid references public.tenant_members(id) on delete set null,
  created_by uuid references public.tenant_members(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  archived_at timestamptz
);
create index widgets_tenant_idx on public.widgets (tenant_id, kind) where archived_at is null;

create table public.widget_bookings (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  widget_id uuid not null references public.widgets(id) on delete cascade,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  member_id uuid references public.tenant_members(id) on delete set null,
  name text not null,
  phone text not null,
  email text not null,
  status text not null default 'booked' check (status in ('booked', 'cancelled')),
  webhook_status int,
  webhook_error text,
  created_at timestamptz not null default now()
);
create index widget_bookings_widget_idx on public.widget_bookings (widget_id, starts_at);
create index widget_bookings_member_idx on public.widget_bookings (member_id, starts_at) where status = 'booked';
-- one booking per member per start time
create unique index widget_bookings_member_slot on public.widget_bookings (member_id, starts_at) where status = 'booked' and member_id is not null;

alter table public.widgets enable row level security;
alter table public.widget_bookings enable row level security;
create policy "widgets: read" on public.widgets for select to authenticated using (private.has_permission(tenant_id, 'widgets', 'view'));
create policy "widgets: add" on public.widgets for insert to authenticated with check (private.has_permission(tenant_id, 'widgets', 'add'));
create policy "widgets: edit" on public.widgets for update to authenticated using (private.has_permission(tenant_id, 'widgets', 'edit')) with check (private.has_permission(tenant_id, 'widgets', 'edit'));
create policy "widget_bookings: read" on public.widget_bookings for select to authenticated using (private.has_permission(tenant_id, 'widgets', 'view'));

/** a team member has a meeting (BizDock Meetings) or a held widget slot overlapping [s, e) */
create or replace function private.member_busy(p_tenant uuid, p_member uuid, s timestamptz, e timestamptz)
returns boolean
language sql
stable
security definer
set search_path to ''
as $$
  select exists (
    select 1 from public.meetings mt
     where mt.tenant_id = p_tenant and mt.assigned_to = p_member and coalesce(mt.status, '') <> 'cancelled'
       and ((mt.meeting_date + mt.start_time) at time zone 'Asia/Kolkata') < e
       and ((mt.meeting_date + coalesce(mt.end_time, mt.start_time + interval '1 hour')) at time zone 'Asia/Kolkata') > s
  ) or exists (
    select 1 from public.widget_bookings b
     where b.member_id = p_member and b.status = 'booked' and b.starts_at < e and b.ends_at > s
  )
$$;

/** the widget's picked team members who are still active, in the order picked */
create or replace function private.widget_members(w public.widgets)
returns uuid[]
language sql
stable
security definer
set search_path to ''
as $$
  select coalesce(array_agg(m.id order by x.n), '{}')
    from jsonb_array_elements_text(coalesce(w.config -> 'members', '[]'::jsonb)) with ordinality as x(v, n)
    join public.tenant_members m on m.id::text = x.v and m.tenant_id = w.tenant_id and m.status = 'active'
$$;

/** what the public embed page needs (no login): an active widget's look and rules */
create or replace function public.widget_public(p_code text)
returns jsonb
language sql
stable
security definer
set search_path to ''
as $$
  select jsonb_build_object(
    'name', w.name,
    'kind', w.kind,
    'color', w.config -> 'color',
    'interval', w.config -> 'interval',
    'days', w.config -> 'days',
    'days_ahead', w.config -> 'days_ahead',
    'team', coalesce(array_length(private.widget_members(w), 1), 0)
  )
  from public.widgets w
  where w.code = p_code and w.is_active and w.archived_at is null
$$;

/**
 * The slots of an active widget between two days (India time): each one's start / end and how many of its team members
 * are free (total 0 = no team picked: always open). Only from now + the notice, up to the booking window.
 */
create or replace function public.widget_slots(p_code text, p_from date, p_to date)
returns table (starts_at timestamptz, ends_at timestamptz, free int, total int)
language plpgsql
stable
security definer
set search_path to ''
as $$
declare
  w public.widgets; c jsonb; v_int int; v_members uuid[]; v_total int;
  v_today date := (now() at time zone 'Asia/Kolkata')::date; v_first date; v_last date; v_earliest timestamptz;
  v_keys text[] := array['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
begin
  select * into w from public.widgets x where x.code = p_code and x.is_active and x.archived_at is null;
  if w.id is null then return; end if;
  c := w.config;
  v_int := greatest(5, least(480, coalesce((c ->> 'interval')::int, 30)));
  v_members := private.widget_members(w);
  v_total := coalesce(array_length(v_members, 1), 0);
  v_earliest := now() + make_interval(mins => (coalesce((c ->> 'notice_hours')::numeric, 1) * 60)::int);
  v_first := greatest(p_from, v_today);
  v_last := least(p_to, v_today + greatest(1, least(365, coalesce((c ->> 'days_ahead')::int, 30))));
  if v_last - v_first > 62 then v_last := v_first + 62; end if;
  return query
    with days as (
      select g::date as d, c -> 'days' -> v_keys[extract(isodow from g)::int] as cfg
        from generate_series(v_first::timestamp, v_last::timestamp, interval '1 day') g
    ), slots as (
      select (t at time zone 'Asia/Kolkata') as s
        from days dd
        cross join lateral generate_series(
          dd.d + (dd.cfg ->> 'start')::time,
          dd.d + (dd.cfg ->> 'end')::time - make_interval(mins => v_int),
          make_interval(mins => v_int)
        ) t
       where coalesce((dd.cfg ->> 'on')::boolean, false)
         and dd.cfg ->> 'start' ~ '^\d{2}:\d{2}' and dd.cfg ->> 'end' ~ '^\d{2}:\d{2}'
    )
    select sl.s, sl.s + make_interval(mins => v_int),
           (select count(*) from unnest(v_members) mid where not private.member_busy(w.tenant_id, mid, sl.s, sl.s + make_interval(mins => v_int)))::int,
           v_total
      from slots sl
     where sl.s >= v_earliest
     order by 1;
end $$;

/**
 * Books a slot (called by the widget-book function only): checks it's still free, picks the team member by round robin
 * among those free (none picked: no one), holds the slot and returns what the webhook gets.
 */
create or replace function public.widget_book(p_code text, p_start timestamptz, p_name text, p_phone text, p_email text)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  w public.widgets; v_slot record; v_members uuid[]; v_n int; v_at int; v_pick uuid; v_id uuid; v_end timestamptz;
  v_member jsonb := null;
begin
  select * into w from public.widgets x where x.code = p_code and x.is_active and x.archived_at is null;
  if w.id is null then raise exception 'This booking calendar isn''t available any more.'; end if;
  if coalesce(trim(p_name), '') = '' then raise exception 'Please enter your name.'; end if;
  if length(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g')) < 10 then raise exception 'Please enter a valid phone number.'; end if;
  if coalesce(p_email, '') !~ '^[^\s@]+@[^\s@]+\.[^\s@]+$' then raise exception 'Please enter a valid email.'; end if;
  -- one booking at a time per widget
  perform pg_advisory_xact_lock(hashtextextended(w.id::text, 0));
  select * into v_slot from public.widget_slots(p_code, (p_start at time zone 'Asia/Kolkata')::date, (p_start at time zone 'Asia/Kolkata')::date) s
   where s.starts_at = p_start;
  if v_slot.starts_at is null then raise exception 'This time can''t be booked. Please pick another.'; end if;
  if v_slot.total > 0 and v_slot.free = 0 then raise exception 'This time was just booked. Please pick another.'; end if;
  v_end := v_slot.ends_at;
  v_members := private.widget_members(w);
  v_n := coalesce(array_length(v_members, 1), 0);
  if v_n > 0 then
    -- round robin: the next free member after the one who got the last booking
    v_at := coalesce(array_position(v_members, w.last_member_id), 0);
    for k in 1..v_n loop
      if not private.member_busy(w.tenant_id, v_members[((v_at + k - 1) % v_n) + 1], p_start, v_end) then
        v_pick := v_members[((v_at + k - 1) % v_n) + 1];
        exit;
      end if;
    end loop;
    if v_pick is null then raise exception 'This time was just booked. Please pick another.'; end if;
    update public.widgets set last_member_id = v_pick where id = w.id;
    select jsonb_build_object('id', m.id, 'name', coalesce(p.full_name, ''), 'email', coalesce(p.email, ''), 'phone', coalesce(p.phone, ''))
      into v_member
      from public.tenant_members m left join public.profiles p on p.id = m.user_id where m.id = v_pick;
  end if;
  insert into public.widget_bookings (tenant_id, widget_id, starts_at, ends_at, member_id, name, phone, email)
  values (w.tenant_id, w.id, p_start, v_end, v_pick, trim(p_name), trim(p_phone), lower(trim(p_email)))
  returning id into v_id;
  return jsonb_build_object(
    'booking_id', v_id, 'tenant_id', w.tenant_id, 'widget_id', w.id, 'widget_name', w.name,
    'starts_at', p_start, 'ends_at', v_end, 'member', v_member,
    'webhook', w.config -> 'webhook', 'thank_you', w.config -> 'thank_you', 'redirect_url', w.config -> 'redirect_url'
  );
end $$;

revoke all on function private.member_busy(uuid, uuid, timestamptz, timestamptz) from public, anon, authenticated;
revoke all on function private.widget_members(public.widgets) from public, anon, authenticated;
grant execute on function public.widget_public(text) to anon, authenticated;
grant execute on function public.widget_slots(text, date, date) to anon, authenticated;
revoke all on function public.widget_book(text, timestamptz, text, text, text) from public, anon, authenticated;
grant execute on function public.widget_book(text, timestamptz, text, text, text) to service_role;
