-- ============================================================
-- Calendar & Webinars: company events (webinars, shoots, meetings, trainings…), holidays and leaves.
--   event_types.kind: event | webinar | holiday | leave
--   An event can be for one business or all; it can have assigned team members.
--   Recurring events are stored as separate dated events sharing a series_id.
-- Who sees what ("Staff calendars" visibility):
--   all  = every event of the businesses they work in
--   team / own = events with nobody assigned (company-wide) + events assigned to them / their team
-- Writing needs calendar.add ("Create company events"). Deleting = cancelling (kept).
-- ============================================================

create table public.event_types (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenants (id) on delete cascade,
  name        text not null,
  kind        text not null default 'event' check (kind in ('event', 'webinar', 'holiday', 'leave')),
  color       text not null default '#64748b',
  is_active   boolean not null default true,
  sort_order  int not null default 0,
  created_at  timestamptz not null default now(),
  unique (tenant_id, name)
);

create table public.webinar_types (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenants (id) on delete cascade,
  name        text not null,
  is_active   boolean not null default true,
  sort_order  int not null default 0,
  created_at  timestamptz not null default now(),
  unique (tenant_id, name)
);

create or replace function private.seed_calendar_masters(t uuid)
returns void language sql security definer set search_path = '' as $$
  insert into public.event_types (tenant_id, name, kind, color, sort_order)
  select t, s.name, s.kind, s.color, s.ord from unnest(
    array['Webinar', 'Podcast', 'Shoot', 'Meeting', 'Community session', 'Training', 'Holiday', 'Leave', 'Day off'],
    array['webinar', 'event', 'event', 'event', 'event', 'event', 'holiday', 'leave', 'leave'],
    array['#8b5cf6', '#0ea5e9', '#f97316', '#64748b', '#16a34a', '#0d9488', '#dc2626', '#d97706', '#94a3b8']
  ) with ordinality as s(name, kind, color, ord)
  on conflict do nothing;
  insert into public.webinar_types (tenant_id, name, sort_order)
  select t, s.name, s.ord from unnest(array['Free webinar', 'Paid masterclass']) with ordinality as s(name, ord)
  on conflict do nothing;
$$;
create or replace function private.seed_new_tenant_calendar()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform private.seed_calendar_masters(new.id);
  return new;
end;
$$;
create trigger tenants_seed_calendar after insert on public.tenants
  for each row execute function private.seed_new_tenant_calendar();
select private.seed_calendar_masters(id) from public.tenants;

create table public.events (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references public.tenants (id) on delete cascade,
  business_id      uuid references public.businesses (id) on delete cascade,   -- null = all businesses
  type_id          uuid not null references public.event_types (id),
  title            text not null,
  topic            text,
  event_date       date not null,
  end_date         date,                                                      -- multi-day (e.g. leave)
  start_time       time,
  end_time         time,
  webinar_type_id  uuid references public.webinar_types (id) on delete set null,
  location         text,
  meeting_link     text,
  zoom_webinar_id  text,
  description      text,
  series_id        uuid,                                                      -- recurring copies share this
  is_cancelled     boolean not null default false,
  created_by       uuid references public.tenant_members (id) on delete set null,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  check (end_date is null or end_date >= event_date)
);
create index events_tenant_date_idx on public.events (tenant_id, event_date);
create index events_series_idx on public.events (series_id);
create trigger events_set_updated_at before update on public.events
  for each row execute function public.set_updated_at();

create table public.event_members (
  event_id   uuid not null references public.events (id) on delete cascade,
  member_id  uuid not null references public.tenant_members (id) on delete cascade,
  tenant_id  uuid not null references public.tenants (id) on delete cascade,
  primary key (event_id, member_id)
);
create index event_members_member_idx on public.event_members (member_id);

-- can the caller see this event?
create or replace function private.can_see_event(e uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.events ev
    where ev.id = e
      and (private.is_member(ev.tenant_id) or private.is_platform_owner())
      and (ev.business_id is null or private.can_access_business(ev.business_id))
      and (
        private.area_scope(ev.tenant_id, 'calendars') = 'all'
        or not exists (select 1 from public.event_members m where m.event_id = ev.id)
        or exists (
          select 1 from public.event_members m
          where m.event_id = ev.id
            and case private.area_scope(ev.tenant_id, 'calendars')
                  when 'team' then m.member_id in (select private.my_team(ev.tenant_id))
                  when 'own'  then m.member_id = private.my_member_id(ev.tenant_id)
                  else false
                end
        )
      )
  )
$$;

revoke execute on all functions in schema private from public, anon;
grant execute on all functions in schema private to authenticated;

alter table public.event_types enable row level security;
create policy "event_types: read" on public.event_types for select to authenticated
  using (private.is_member(tenant_id) or private.is_platform_owner());
create policy "event_types: write" on public.event_types for all to authenticated
  using (private.has_permission(tenant_id, 'masters', 'edit'))
  with check (private.has_permission(tenant_id, 'masters', 'edit'));

alter table public.webinar_types enable row level security;
create policy "webinar_types: read" on public.webinar_types for select to authenticated
  using (private.is_member(tenant_id) or private.is_platform_owner());
create policy "webinar_types: write" on public.webinar_types for all to authenticated
  using (private.has_permission(tenant_id, 'masters', 'edit'))
  with check (private.has_permission(tenant_id, 'masters', 'edit'));

alter table public.events enable row level security;
create policy "events: read" on public.events for select to authenticated
  using (private.can_see_event(id));
create policy "events: insert" on public.events for insert to authenticated
  with check (private.has_permission(tenant_id, 'calendar', 'add')
              and (business_id is null or private.can_access_business(business_id)));
create policy "events: update" on public.events for update to authenticated
  using (private.has_permission(tenant_id, 'calendar', 'add') and private.can_see_event(id))
  with check (business_id is null or private.can_access_business(business_id));

alter table public.event_members enable row level security;
create policy "event_members: read" on public.event_members for select to authenticated
  using (private.is_member(tenant_id) or private.is_platform_owner());
create policy "event_members: write" on public.event_members for all to authenticated
  using (private.has_permission(tenant_id, 'calendar', 'add'))
  with check (private.has_permission(tenant_id, 'calendar', 'add'));

grant select, insert, update, delete on public.event_types, public.webinar_types, public.event_members to authenticated;
grant select, insert, update on public.events to authenticated;
revoke all on public.event_types, public.webinar_types, public.events, public.event_members from anon;

-- Demo data (Viral): a webinar, a shoot, a weekly team meeting series, a holiday and a leave, inserted with execute_sql.
