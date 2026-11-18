-- Git graph (What's new): platform owners, and owner / support logins of a workspace
create or replace function public.can_see_dev() returns boolean language sql stable security definer set search_path to '' as $$
  select private.is_platform_owner() or exists (
    select 1 from public.tenant_members m join public.roles r on r.id = m.role_id
     where m.user_id = (select auth.uid()) and m.status = 'active' and (m.is_support or r.level <= 1)
  )
$$;
revoke all on function public.can_see_dev() from public, anon;
grant execute on function public.can_see_dev() to authenticated;
