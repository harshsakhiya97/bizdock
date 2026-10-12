-- Checking out again on the same day moves the check-out time to now.
create or replace function public.attendance_check_out(p_tenant uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  me uuid := private.my_member_id(p_tenant);
  a  uuid;
begin
  select id into a from public.attendance
  where member_id = me and work_date = private.today_in(p_tenant) and check_in is not null;
  if a is null then raise exception 'Check in first.'; end if;
  update public.attendance_breaks set ended_at = now() where attendance_id = a and ended_at is null;
  update public.attendance set check_out = now() where id = a;
end;
$$;
