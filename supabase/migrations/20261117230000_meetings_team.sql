-- Meetings for everyone: a meeting is with a lead (kind 'lead') or internal (kind 'team', company level: no lead, no
-- business), has several team members (members[], the first one is also assigned_to), and can be cancelled.
-- Anyone in the team can add one. People see the meetings they are in or added; the Meetings "view" permission still
-- shows every lead meeting (lead page, dashboard).

alter table public.meetings add column if not exists kind text not null default 'lead';
alter table public.meetings add column if not exists title text;
alter table public.meetings add column if not exists members uuid[] not null default '{}';
alter table public.meetings alter column lead_id drop not null;
alter table public.meetings alter column business_id drop not null;

alter table public.meetings drop constraint if exists meetings_kind_check;
alter table public.meetings add constraint meetings_kind_check check (kind in ('lead', 'team'));
alter table public.meetings drop constraint if exists meetings_kind_fields;
alter table public.meetings add constraint meetings_kind_fields check (
  (kind = 'lead' and lead_id is not null and business_id is not null) or (kind = 'team' and lead_id is null and business_id is null)
);
alter table public.meetings drop constraint if exists meetings_status_check;
alter table public.meetings add constraint meetings_status_check check (status in ('scheduled', 'done', 'no_show', 'cancelled'));

-- existing meetings: their team member is the first (only) member
update public.meetings set members = array[assigned_to] where assigned_to is not null and cardinality(members) = 0;
create index if not exists meetings_members_idx on public.meetings using gin (members);

-- members[] and assigned_to stay in step (workflows and older code set assigned_to only)
create or replace function private.meeting_members_sync() returns trigger language plpgsql set search_path to '' as $$
begin
  new.members := coalesce(new.members, '{}');
  if tg_op = 'INSERT' and cardinality(new.members) = 0 and new.assigned_to is not null then
    new.members := array[new.assigned_to];
  elsif tg_op = 'UPDATE' and new.members = old.members and new.assigned_to is distinct from old.assigned_to and new.assigned_to is not null then
    new.members := array_prepend(new.assigned_to, array_remove(new.members, new.assigned_to));
  end if;
  -- no blanks, no repeats, order kept
  new.members := coalesce((
    select array_agg(x order by o) from (
      select distinct on (x) x, o from unnest(new.members) with ordinality u(x, o) where x is not null order by x, o
    ) s), '{}');
  new.assigned_to := new.members[1];
  return new;
end $$;
drop trigger if exists meetings_members_sync on public.meetings;
create trigger meetings_members_sync before insert or update on public.meetings for each row execute function private.meeting_members_sync();

-- access
drop policy if exists "meetings: read" on public.meetings;
drop policy if exists "meetings: insert" on public.meetings;
drop policy if exists "meetings: update" on public.meetings;
drop policy if exists "meetings: delete" on public.meetings;

create policy "meetings: read" on public.meetings for select using (
  private.is_member(tenant_id) and (
    private.my_member_id(tenant_id) = any (members)
    or created_by = private.my_member_id(tenant_id)
    or (kind = 'lead' and private.has_permission(tenant_id, 'meetings', 'view') and private.can_access_sub(business_id, sub_business_id)
        and exists (select 1 from public.leads l where l.id = meetings.lead_id and private.can_see_lead(l.tenant_id, l.business_id, l.owner_id)))
  )
);
create policy "meetings: insert" on public.meetings for insert with check (
  private.is_member(tenant_id) and (
    kind = 'team'
    or (private.can_access_business(business_id) and private.can_access_sub(business_id, sub_business_id)
        and exists (select 1 from public.leads l where l.id = meetings.lead_id and l.tenant_id = meetings.tenant_id and private.can_see_lead(l.tenant_id, l.business_id, l.owner_id)))
  )
);
create policy "meetings: update" on public.meetings for update using (
  private.is_member(tenant_id) and (
    private.my_member_id(tenant_id) = any (members)
    or created_by = private.my_member_id(tenant_id)
    or (kind = 'lead' and private.has_permission(tenant_id, 'meetings', 'edit') and private.can_access_sub(business_id, sub_business_id)
        and exists (select 1 from public.leads l where l.id = meetings.lead_id and private.can_see_lead(l.tenant_id, l.business_id, l.owner_id)))
  )
) with check (
  private.is_member(tenant_id) and (kind = 'team' or (private.can_access_business(business_id) and private.can_access_sub(business_id, sub_business_id)))
);
create policy "meetings: delete" on public.meetings for delete using (
  private.is_member(tenant_id) and (
    created_by = private.my_member_id(tenant_id)
    or (private.has_permission(tenant_id, 'meetings', 'delete') and (kind = 'team' or private.can_access_sub(business_id, sub_business_id)))
  )
);

-- booking calendars: a member is busy in any meeting they are in
create or replace function private.member_busy(p_tenant uuid, p_member uuid, s timestamptz, e timestamptz) returns boolean
language sql stable security definer set search_path to '' as $$
  select exists (
    select 1 from public.meetings mt
     where mt.tenant_id = p_tenant and p_member = any (mt.members) and mt.status = 'scheduled'
       and ((mt.meeting_date + mt.start_time) at time zone 'Asia/Kolkata') < e
       and ((mt.meeting_date + coalesce(mt.end_time, mt.start_time + interval '1 hour')) at time zone 'Asia/Kolkata') > s
  ) or exists (
    -- slots held by bookings of widgets that still exist
    select 1 from public.widget_bookings b
      join public.widgets w on w.id = b.widget_id and w.archived_at is null
     where b.member_id = p_member and b.status = 'booked' and b.starts_at < e and b.ends_at > s
  )
$$;

-- the meeting drawer: who is busy at that time (any meeting of theirs, or a booking-calendar slot), for the
-- "Available / Busy" next to each member. Other people's meetings show only their time and kind.
create or replace function public.meeting_busy(p_tenant uuid, p_date date, p_start time, p_end time, p_except uuid default null)
returns table (member_id uuid, start_time time, end_time time, label text)
language sql stable security definer set search_path to '' as $$
  select m_id, mt.start_time, mt.end_time,
         case when mt.kind = 'team' then 'Team meeting' else 'Lead meeting' end
    from public.meetings mt cross join lateral unnest(mt.members) m_id
   where private.is_member(p_tenant) and mt.tenant_id = p_tenant and mt.meeting_date = p_date and mt.status = 'scheduled'
     and (p_except is null or mt.id <> p_except) and mt.start_time < p_end and mt.end_time > p_start
  union all
  select b.member_id, (b.starts_at at time zone 'Asia/Kolkata')::time, (b.ends_at at time zone 'Asia/Kolkata')::time, 'Booking calendar slot'
    from public.widget_bookings b join public.widgets w on w.id = b.widget_id and w.archived_at is null
   where private.is_member(p_tenant) and w.tenant_id = p_tenant and b.member_id is not null and b.status = 'booked'
     and b.starts_at < ((p_date + p_end) at time zone 'Asia/Kolkata') and b.ends_at > ((p_date + p_start) at time zone 'Asia/Kolkata')
     and not exists (
       -- the booking already became a meeting of that member at that time
       select 1 from public.meetings mt where mt.tenant_id = p_tenant and b.member_id = any (mt.members) and mt.status = 'scheduled'
          and ((mt.meeting_date + mt.start_time) at time zone 'Asia/Kolkata') = b.starts_at
     )
$$;
revoke all on function public.meeting_busy(uuid, date, time, time, uuid) from public, anon;
grant execute on function public.meeting_busy(uuid, date, time, time, uuid) to authenticated;
