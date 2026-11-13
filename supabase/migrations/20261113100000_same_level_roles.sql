-- Team: a person can give roles at their own level too (not only below), and manage people at their own level.
-- Never above their level, never the Owner role / Owner people (except Tech Support), and never their own role.
create or replace function private.guard_member_level()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  mine int;
  new_level int;
  old_level int;
begin
  if (select auth.uid()) is null or private.is_platform_owner() then
    return coalesce(new, old);
  end if;
  mine := coalesce(private.my_level(coalesce(new.tenant_id, old.tenant_id)), 2147483647);

  if tg_op in ('INSERT', 'UPDATE') then
    select level into new_level from public.roles where id = new.role_id;
    if new_level < mine or (new_level <= 1 and mine >= 1) then raise exception 'You can only give roles at or below your own level'; end if;
    if new.reports_to = new.id then raise exception 'A person cannot report to themselves'; end if;
    if new.reports_to is not null and not exists (
      select 1 from public.tenant_members where id = new.reports_to and tenant_id = new.tenant_id) then
      raise exception 'Reports to must be someone in this workspace';
    end if;
  end if;
  if tg_op in ('UPDATE', 'DELETE') then
    select level into old_level from public.roles where id = old.role_id;
    if old_level < mine or (old_level <= 1 and mine >= 1) then raise exception 'You can only change people at or below your own level'; end if;
    if old.user_id = (select auth.uid()) and mine > 1 and (tg_op = 'DELETE' or new.role_id is distinct from old.role_id) then
      raise exception 'You cannot change your own role';
    end if;
  end if;
  return coalesce(new, old);
end;
$$;

create or replace function private.can_manage_member(member uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select private.is_platform_owner() or exists (
    select 1 from public.tenant_members m join public.roles r on r.id = m.role_id
    cross join lateral (select coalesce(private.my_level(m.tenant_id), 2147483647) as mine) x
    where m.id = member and r.level >= x.mine and (r.level > 1 or x.mine = 0)
      and (m.user_id <> (select auth.uid()) or x.mine <= 1)
  )
$$;
