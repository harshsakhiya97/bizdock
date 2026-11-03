-- A deleted booking calendar's held slots no longer make its team members busy.
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
    -- slots held by bookings of widgets that still exist
    select 1 from public.widget_bookings b
      join public.widgets w on w.id = b.widget_id and w.archived_at is null
     where b.member_id = p_member and b.status = 'booked' and b.starts_at < e and b.ends_at > s
  )
$$;
revoke all on function private.member_busy(uuid, uuid, timestamptz, timestamptz) from public, anon, authenticated;
