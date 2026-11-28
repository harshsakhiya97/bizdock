-- For now every active member sees the owner dashboard (was: platform owner, system role or level 0–1)
create or replace function private.is_owner_view(t uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select private.is_platform_owner() or exists (
    select 1 from public.tenant_members m
     where m.tenant_id = t and m.user_id = (select auth.uid()) and m.status = 'active')
$$;
