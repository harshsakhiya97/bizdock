-- The Tech Support Team member (Harsh) shows in every team-member list (owners, meetings, assignments…); attendance
-- and salaries still leave it out.
create or replace function public.member_directory(p_tenant uuid)
returns table(id uuid, name text, role_level integer)
language sql stable security definer set search_path to '' as $$
  select m.id, coalesce(nullif(p.full_name, ''), split_part(p.email, '@', 1), 'Team member'), r.level
  from public.tenant_members m
  join public.roles r on r.id = m.role_id
  left join public.profiles p on p.id = m.user_id
  where m.tenant_id = p_tenant and m.status = 'active'
    and (private.is_member(p_tenant) or private.is_platform_owner())
  order by 2
$$;
