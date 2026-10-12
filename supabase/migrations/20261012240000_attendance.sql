-- ============================================================
-- Attendance: check in / out, tea & lunch breaks, late marking, corrections, weekly offs.
-- Holidays and leaves come from the Calendar (event kinds 'holiday' / 'leave').
-- Who sees whose attendance: "Attendance" visibility (all / team / own).
-- Correcting attendance and changing the rules: attendance.edit (Owner always).
-- Everyone checks themselves in and out (their own row only, through the functions below).
-- ============================================================

create table public.attendance_settings (
  tenant_id         uuid primary key references public.tenants (id) on delete cascade,
  timezone          text not null default 'Asia/Kolkata',
  checkin_start     time not null default '09:30',
  checkin_end       time not null default '09:40',      -- checking in after this = late
  half_day_hours    numeric(4, 2) not null default 4,    -- worked less than this = half day
  tea_break_min     int not null default 15,
  lunch_break_min   int not null default 30,
  weekly_off        smallint[] not null default '{0}',   -- 0 = Sunday … 6 = Saturday
  updated_at        timestamptz not null default now()
);

alter table public.tenant_members add column weekly_off smallint[];   -- null = the workspace default

create table public.attendance (
  id                 uuid primary key default gen_random_uuid(),
  tenant_id          uuid not null references public.tenants (id) on delete cascade,
  member_id          uuid not null references public.tenant_members (id) on delete cascade,
  work_date          date not null,
  check_in           timestamptz,
  check_out          timestamptz,
  is_late            boolean not null default false,
  late_minutes       int not null default 0,
  note               text,
  corrected_by       uuid references public.tenant_members (id) on delete set null,
  correction_reason  text,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  unique (member_id, work_date),
  check (check_out is null or check_in is null or check_out >= check_in)
);
create index attendance_tenant_date_idx on public.attendance (tenant_id, work_date);
create trigger attendance_set_updated_at before update on public.attendance
  for each row execute function public.set_updated_at();

create table public.attendance_breaks (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references public.tenants (id) on delete cascade,
  attendance_id  uuid not null references public.attendance (id) on delete cascade,
  kind           text not null default 'tea' check (kind in ('tea', 'lunch', 'other')),
  started_at     timestamptz not null default now(),
  ended_at       timestamptz
);
create index attendance_breaks_att_idx on public.attendance_breaks (attendance_id);

-- may the caller see this person's attendance?
create or replace function private.can_see_attendance(t uuid, member uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select case private.area_scope(t, 'attendance')
    when 'all'  then private.is_member(t) or private.is_platform_owner()
    when 'team' then member in (select private.my_team(t))
    when 'own'  then member = private.my_member_id(t)
    else member = private.my_member_id(t)    -- everyone sees their own log
  end
$$;

-- the late flag and minutes for a check-in time
create or replace function private.lateness(t uuid, at_time timestamptz)
returns int language sql stable security definer set search_path = '' as $$
  select greatest(0, floor(extract(epoch from (
           (at_time at time zone s.timezone)::time - s.checkin_end)) / 60)::int)
  from public.attendance_settings s where s.tenant_id = t
$$;

create or replace function private.today_in(t uuid)
returns date language sql stable security definer set search_path = '' as $$
  select (now() at time zone coalesce((select timezone from public.attendance_settings where tenant_id = t), 'Asia/Kolkata'))::date
$$;

revoke execute on all functions in schema private from public, anon;
grant execute on all functions in schema private to authenticated;

-- ---------- the caller's own day ----------
create or replace function public.attendance_check_in(p_tenant uuid, p_note text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare
  me uuid := private.my_member_id(p_tenant);
  late int;
begin
  if me is null then raise exception 'You are not part of this workspace.'; end if;
  insert into public.attendance_settings (tenant_id) values (p_tenant) on conflict do nothing;
  late := coalesce(private.lateness(p_tenant, now()), 0);
  insert into public.attendance (tenant_id, member_id, work_date, check_in, is_late, late_minutes, note)
  values (p_tenant, me, private.today_in(p_tenant), now(), late > 0, late, nullif(trim(p_note), ''))
  on conflict (member_id, work_date) do nothing;
  if not found then raise exception 'You have already checked in today.'; end if;
end;
$$;

create or replace function public.attendance_check_out(p_tenant uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  me uuid := private.my_member_id(p_tenant);
  a  uuid;
begin
  select id into a from public.attendance
  where member_id = me and work_date = private.today_in(p_tenant) and check_in is not null and check_out is null;
  if a is null then raise exception 'Check in first.'; end if;
  update public.attendance_breaks set ended_at = now() where attendance_id = a and ended_at is null;
  update public.attendance set check_out = now() where id = a;
end;
$$;

create or replace function public.attendance_break(p_tenant uuid, p_kind text)
returns void language plpgsql security definer set search_path = '' as $$
declare
  me uuid := private.my_member_id(p_tenant);
  a  uuid;
begin
  select id into a from public.attendance
  where member_id = me and work_date = private.today_in(p_tenant) and check_in is not null and check_out is null;
  if a is null then raise exception 'Check in first.'; end if;
  if p_kind = 'end' then
    update public.attendance_breaks set ended_at = now() where attendance_id = a and ended_at is null;
  else
    if exists (select 1 from public.attendance_breaks where attendance_id = a and ended_at is null) then
      raise exception 'You are already on a break.';
    end if;
    insert into public.attendance_breaks (tenant_id, attendance_id, kind)
    values (p_tenant, a, case when p_kind in ('tea', 'lunch') then p_kind else 'other' end);
  end if;
end;
$$;

-- ---------- corrections (attendance.edit) ----------
create or replace function public.attendance_correct(p_tenant uuid, p_member uuid, p_date date, p_in timestamptz, p_out timestamptz, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare
  late int;
begin
  if not private.has_permission(p_tenant, 'attendance', 'edit') then
    raise exception 'You don’t have permission to correct attendance.';
  end if;
  if not exists (select 1 from public.tenant_members where id = p_member and tenant_id = p_tenant) then
    raise exception 'Pick a team member.';
  end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Give a reason for the correction.'; end if;
  if p_out is not null and p_in is not null and p_out < p_in then raise exception 'Check-out is before check-in.'; end if;
  insert into public.attendance_settings (tenant_id) values (p_tenant) on conflict do nothing;
  late := case when p_in is null then 0 else coalesce(private.lateness(p_tenant, p_in), 0) end;
  if p_in is null and p_out is null then
    delete from public.attendance where member_id = p_member and work_date = p_date;
    return;
  end if;
  insert into public.attendance (tenant_id, member_id, work_date, check_in, check_out, is_late, late_minutes, corrected_by, correction_reason)
  values (p_tenant, p_member, p_date, p_in, p_out, late > 0, late, private.my_member_id(p_tenant), trim(p_reason))
  on conflict (member_id, work_date) do update
  set check_in = excluded.check_in, check_out = excluded.check_out, is_late = excluded.is_late,
      late_minutes = excluded.late_minutes, corrected_by = excluded.corrected_by, correction_reason = excluded.correction_reason;
end;
$$;

-- weekly off for one person (null = workspace default)
create or replace function public.attendance_set_weekly_off(p_tenant uuid, p_member uuid, p_days smallint[])
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not private.has_permission(p_tenant, 'attendance', 'edit') then
    raise exception 'You don’t have permission to change weekly offs.';
  end if;
  update public.tenant_members set weekly_off = p_days where id = p_member and tenant_id = p_tenant;
end;
$$;

-- the people whose attendance the caller may see, with their weekly off
create or replace function public.attendance_people(p_tenant uuid)
returns table (id uuid, name text, weekly_off smallint[])
language sql stable security definer set search_path = '' as $$
  select m.id, coalesce(nullif(p.full_name, ''), split_part(p.email, '@', 1), 'Team member'),
         coalesce(m.weekly_off, s.weekly_off, '{0}')
  from public.tenant_members m
  left join public.profiles p on p.id = m.user_id
  left join public.attendance_settings s on s.tenant_id = m.tenant_id
  where m.tenant_id = p_tenant and m.status = 'active' and not m.is_support
    and private.can_see_attendance(p_tenant, m.id)
  order by 2
$$;

revoke execute on function public.attendance_check_in(uuid, text), public.attendance_check_out(uuid), public.attendance_break(uuid, text),
  public.attendance_correct(uuid, uuid, date, timestamptz, timestamptz, text), public.attendance_set_weekly_off(uuid, uuid, smallint[]),
  public.attendance_people(uuid) from public, anon;
grant execute on function public.attendance_check_in(uuid, text), public.attendance_check_out(uuid), public.attendance_break(uuid, text),
  public.attendance_correct(uuid, uuid, date, timestamptz, timestamptz, text), public.attendance_set_weekly_off(uuid, uuid, smallint[]),
  public.attendance_people(uuid) to authenticated;

-- ---------- row security (reads; writes go through the functions above) ----------
alter table public.attendance_settings enable row level security;
create policy "attendance_settings: read" on public.attendance_settings for select to authenticated
  using (private.is_member(tenant_id) or private.is_platform_owner());
create policy "attendance_settings: write" on public.attendance_settings for all to authenticated
  using (private.has_permission(tenant_id, 'attendance', 'edit'))
  with check (private.has_permission(tenant_id, 'attendance', 'edit'));

alter table public.attendance enable row level security;
create policy "attendance: read" on public.attendance for select to authenticated
  using (private.can_see_attendance(tenant_id, member_id));

alter table public.attendance_breaks enable row level security;
create policy "attendance_breaks: read" on public.attendance_breaks for select to authenticated
  using (exists (select 1 from public.attendance a where a.id = attendance_id and private.can_see_attendance(a.tenant_id, a.member_id)));

grant select, insert, update on public.attendance_settings to authenticated;
grant select on public.attendance, public.attendance_breaks to authenticated;
revoke all on public.attendance_settings, public.attendance, public.attendance_breaks from anon;

insert into public.attendance_settings (tenant_id) select id from public.tenants on conflict do nothing;

-- Demo data (Viral): Rohan, Priya and Karan from 1 Oct to today, with a few late days and breaks, inserted with execute_sql.
