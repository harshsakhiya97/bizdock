-- the email of a team member picked on a Booking Calendar (its workflow's sample shows it as member_email),
-- for anyone who can add / edit widgets (reading team members' emails otherwise needs Team permission)
create or replace function public.widget_member_email(p_member uuid)
returns text language sql stable security definer set search_path = '' as $$
  select p.email
  from public.tenant_members m
  join public.profiles p on p.id = m.user_id
  where m.id = p_member
    and (private.has_permission(m.tenant_id, 'widgets', 'edit') or private.has_permission(m.tenant_id, 'widgets', 'add'))
$$;
revoke all on function public.widget_member_email(uuid) from public, anon;
grant execute on function public.widget_member_email(uuid) to authenticated;
