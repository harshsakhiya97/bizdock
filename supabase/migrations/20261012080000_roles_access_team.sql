-- Applied in parts (Supabase tool): columns, functions, policies, revokes, starter-role updates.
-- The Admin -> Owner rename was run by Harsh in the SQL editor.
-- ============================================================
-- Roles, access control and team (tenant panel)
--
-- Roles have a LEVEL. Lower number = more senior.
--   0  Tech Support Team (BizDock, hidden, cannot be changed)
--   1  Owner (one per client, fixed: has everything, cannot be edited or deleted)
--   2  Business Manager
--   3+ roles the client creates
-- Nobody can create, edit, delete or assign a role at their own level or above.
--
-- Permissions (roles.permissions, or tenant_members.permissions when a person
-- has custom access) are jsonb:
--   { "scope":  { "leads": "all|team|own|none", "customers": ..., "sales": ...,
--                 "dashboards": ..., "calendars": ..., "attendance": ... },
--     "<module>": { "<action>": true, ... },
--     "mode": { "view_only": true } }
-- "team" = the person plus everyone who reports to them (tenant_members.reports_to).
-- ============================================================

-- ---------- roles: level ----------
alter table public.roles add column level int not null default 3 check (level >= 0);

-- ---------- members: team details + custom access ----------
alter table public.tenant_members
  add column reports_to  uuid references public.tenant_members (id) on delete set null,
  add column department  text,
  add column designation text,
  add column joined_on   date,
  add column permissions jsonb;           -- null = follows the role
create index tenant_members_reports_to_idx on public.tenant_members (reports_to);

-- ---------- member's branch inside a business ----------
alter table public.member_businesses
  add column branch_id uuid,
  add foreign key (branch_id, business_id) references public.branches (id, business_id) on delete set null (branch_id);
create index member_businesses_branch_idx on public.member_businesses (branch_id);

-- ---------- per-client settings ----------
create table public.tenant_settings (
  tenant_id        uuid primary key references public.tenants (id) on delete cascade,
  default_password text,
  updated_at       timestamptz not null default now()
);
create trigger tenant_settings_set_updated_at before update on public.tenant_settings
  for each row execute function public.set_updated_at();

-- ============================================================
-- Permission presets for the starter roles
-- ============================================================
create or replace function private.preset(kind text)
returns jsonb language sql immutable set search_path = '' as $$
  select case kind
    when 'owner' then '{
      "scope": {"leads":"all","customers":"all","sales":"all","dashboards":"all","calendars":"all","attendance":"all"},
      "leads": {"add":true,"edit":true,"delete":true,"assign":true,"export":true},
      "follow_ups": {"add":true},
      "deals": {"add":true,"edit":true},
      "payments": {"view":true,"add":true,"verify":true},
      "collections": {"view":true},
      "finance": {"view":true},
      "customers": {"edit":true},
      "tasks": {"view":true},
      "calendar": {"add":true},
      "team": {"view":true,"add":true,"edit":true},
      "businesses": {"view":true,"add":true,"edit":true,"delete":true},
      "masters": {"edit":true},
      "settings": {"edit":true},
      "activity": {"view":true},
      "access": {"edit":true}
    }'::jsonb
    when 'manager' then '{
      "scope": {"leads":"team","customers":"team","sales":"team","dashboards":"team","calendars":"team","attendance":"team"},
      "leads": {"add":true,"edit":true,"assign":true,"export":true},
      "follow_ups": {"add":true},
      "deals": {"add":true,"edit":true},
      "payments": {"view":true,"add":true},
      "collections": {"view":true},
      "customers": {"edit":true},
      "tasks": {"view":true},
      "calendar": {"add":true},
      "team": {"view":true,"add":true,"edit":true},
      "businesses": {"view":true}
    }'::jsonb
    when 'caller' then '{
      "scope": {"leads":"own","customers":"own","sales":"own","dashboards":"own","calendars":"own","attendance":"own"},
      "leads": {"add":true,"edit":true},
      "follow_ups": {"add":true},
      "deals": {"add":true},
      "payments": {"view":true,"add":true},
      "collections": {"view":true},
      "tasks": {"view":true}
    }'::jsonb
    when 'accounts' then '{
      "scope": {"leads":"none","customers":"all","sales":"all","dashboards":"own","calendars":"own","attendance":"own"},
      "deals": {"edit":true},
      "payments": {"view":true,"add":true,"verify":true},
      "collections": {"view":true},
      "finance": {"view":true},
      "customers": {"edit":true},
      "tasks": {"view":true}
    }'::jsonb
    else '{}'::jsonb
  end
$$;

-- ============================================================
-- Helpers
-- ============================================================

-- Caller's level in a tenant (0 for the platform owner, null if not a member)
create or replace function private.my_level(t uuid)
returns int language sql stable security definer set search_path = '' as $$
  select case when private.is_platform_owner() then 0 else (
    select min(r.level)
    from public.tenant_members m join public.roles r on r.id = m.role_id
    where m.tenant_id = t and m.user_id = (select auth.uid()) and m.status = 'active'
  ) end
$$;

-- Owner, Tech Support and the platform owner can do everything.
-- Otherwise the person's custom access, or their role's. View-only blocks every non-view action.
create or replace function private.has_permission(t uuid, module text, action text)
returns boolean language sql stable security definer set search_path = '' as $$
  select private.is_platform_owner() or exists (
    select 1
    from public.tenant_members m
    join public.roles r on r.id = m.role_id
    cross join lateral (select coalesce(m.permissions, r.permissions) as p) x
    where m.tenant_id = t and m.user_id = (select auth.uid()) and m.status = 'active'
      and (
        r.is_system or r.level <= 1
        or (
          coalesce((x.p -> module ->> action)::boolean, false)
          and not (action <> 'view' and coalesce((x.p -> 'mode' ->> 'view_only')::boolean, false))
        )
      )
  )
$$;

-- Can the caller manage this member (their role is below the caller's level)?
create or replace function private.can_manage_member(member uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select private.is_platform_owner() or exists (
    select 1 from public.tenant_members m join public.roles r on r.id = m.role_id
    where m.id = member and r.level > coalesce(private.my_level(m.tenant_id), 2147483647)
  )
$$;

revoke execute on all functions in schema private from public, anon;
grant execute on all functions in schema private to authenticated;

-- ============================================================
-- Guards: the level rule
-- ============================================================
create or replace function private.guard_role_level()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  mine int;
begin
  if (select auth.uid()) is null or private.is_platform_owner() then
    return coalesce(new, old);
  end if;
  mine := coalesce(private.my_level(coalesce(new.tenant_id, old.tenant_id)), 2147483647);

  if tg_op = 'INSERT' then
    if new.level < 3 then raise exception 'New roles start from level 3'; end if;
    if new.level <= mine then raise exception 'You can only create roles below your own level'; end if;
  elsif tg_op = 'UPDATE' then
    if old.level <= 1 then raise exception 'The Owner role cannot be changed'; end if;
    if old.level <= mine or new.level <= mine then
      raise exception 'You can only change roles below your own level';
    end if;
    if new.level < 2 then raise exception 'Only the Owner role can be level 1'; end if;
  elsif tg_op = 'DELETE' then
    if old.level <= 1 then raise exception 'The Owner role cannot be deleted'; end if;
    if old.level <= mine then raise exception 'You can only delete roles below your own level'; end if;
    if exists (select 1 from public.tenant_members where role_id = old.id) then
      raise exception 'This role still has people. Give them another role first.';
    end if;
  end if;
  return coalesce(new, old);
end;
$$;

create trigger roles_level_guard before insert or update or delete on public.roles
  for each row execute function private.guard_role_level();

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
    if new_level <= mine then raise exception 'You can only give roles below your own level'; end if;
    if new.reports_to = new.id then raise exception 'A person cannot report to themselves'; end if;
    if new.reports_to is not null and not exists (
      select 1 from public.tenant_members where id = new.reports_to and tenant_id = new.tenant_id) then
      raise exception 'Reports to must be someone in this workspace';
    end if;
  end if;
  if tg_op in ('UPDATE', 'DELETE') then
    select level into old_level from public.roles where id = old.role_id;
    if old_level <= mine then raise exception 'You can only change people below your own level'; end if;
  end if;
  return coalesce(new, old);
end;
$$;

create trigger tenant_members_level_guard before insert or update or delete on public.tenant_members
  for each row execute function private.guard_member_level();

-- ============================================================
-- Policies
-- ============================================================
alter policy "roles: insert" on public.roles
  with check (private.has_permission(tenant_id, 'access', 'edit'));
alter policy "roles: update" on public.roles
  using (private.has_permission(tenant_id, 'access', 'edit'))
  with check (private.has_permission(tenant_id, 'access', 'edit'));
alter policy "roles: delete" on public.roles
  using (private.has_permission(tenant_id, 'access', 'edit'));

alter policy "members: update" on public.tenant_members
  using (private.has_permission(tenant_id, 'team', 'edit') or private.has_permission(tenant_id, 'access', 'edit'))
  with check (private.has_permission(tenant_id, 'team', 'edit') or private.has_permission(tenant_id, 'access', 'edit'));
alter policy "members: delete" on public.tenant_members
  using (private.has_permission(tenant_id, 'team', 'edit'));

alter policy "member_businesses: insert" on public.member_businesses
  with check ((private.has_permission(tenant_id, 'team', 'add') or private.has_permission(tenant_id, 'team', 'edit'))
              and private.can_manage_member(member_id));
alter policy "member_businesses: delete" on public.member_businesses
  using (private.has_permission(tenant_id, 'team', 'edit') and private.can_manage_member(member_id));
create policy "member_businesses: update" on public.member_businesses for update to authenticated
  using (private.has_permission(tenant_id, 'team', 'edit') and private.can_manage_member(member_id))
  with check (private.has_permission(tenant_id, 'team', 'edit') and private.can_manage_member(member_id));

alter table public.tenant_settings enable row level security;
create policy "tenant_settings: read" on public.tenant_settings for select to authenticated
  using (private.has_permission(tenant_id, 'team', 'add'));
create policy "tenant_settings: insert" on public.tenant_settings for insert to authenticated
  with check (private.has_permission(tenant_id, 'team', 'add'));
create policy "tenant_settings: update" on public.tenant_settings for update to authenticated
  using (private.has_permission(tenant_id, 'team', 'add'))
  with check (private.has_permission(tenant_id, 'team', 'add'));
grant select, insert, update on public.tenant_settings to authenticated;
revoke all on public.tenant_settings from anon;
grant update on public.member_businesses to authenticated;

-- ============================================================
-- Last login per member (auth.users is not readable from the app)
-- ============================================================
create or replace function public.team_last_logins(p_tenant uuid)
returns table (user_id uuid, last_sign_in_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select u.id, u.last_sign_in_at
  from public.tenant_members m join auth.users u on u.id = m.user_id
  where m.tenant_id = p_tenant and private.has_permission(p_tenant, 'team', 'view')
$$;
revoke execute on function public.team_last_logins(uuid) from public, anon;
grant execute on function public.team_last_logins(uuid) to authenticated;

-- ============================================================
-- Starter roles for new clients
-- ============================================================
create or replace function private.seed_new_tenant()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  support_role uuid;
begin
  insert into public.roles (tenant_id, name, description, permissions, is_system, level)
  values (new.id, 'Tech Support Team', 'BizDock support. Full access; cannot be edited or removed.',
          private.preset('owner'), true, 0)
  returning id into support_role;

  insert into public.roles (tenant_id, name, description, permissions, level) values
    (new.id, 'Owner', 'Owns the workspace. Has everything; cannot be changed.', private.preset('owner'), 1),
    (new.id, 'Business Manager', 'Runs the businesses they are given, with their team.', private.preset('manager'), 2),
    (new.id, 'Caller', 'Calls leads, logs follow-ups and records sales.', private.preset('caller'), 3),
    (new.id, 'Accounts', 'Handles payments, collections and finance.', private.preset('accounts'), 3);

  insert into public.tenant_members (tenant_id, user_id, role_id, all_businesses, is_support)
  select new.id, po.user_id, support_role, true, true from public.platform_owners po;

  return new;
end;
$$;

-- ============================================================
-- Existing clients: move the starter roles to the new model
-- (no one holds these roles yet; Tech Support keeps its members)
-- ============================================================
update public.roles set level = 0, permissions = private.preset('owner') where is_system;
update public.roles set name = 'Owner', level = 1, permissions = private.preset('owner'),
  description = 'Owns the workspace. Has everything; cannot be changed.'
  where name = 'Admin' and not is_system;
update public.roles set level = 2, permissions = private.preset('manager'),
  description = 'Runs the businesses they are given, with their team.'
  where name = 'Business Manager' and not is_system;
update public.roles set level = 3, permissions = private.preset('caller'),
  description = 'Calls leads, logs follow-ups and records sales.'
  where name = 'Caller' and not is_system;
update public.roles set level = 3, permissions = private.preset('accounts'),
  description = 'Handles payments, collections and finance.'
  where name = 'Accounts' and not is_system;

-- one Owner (level 1) and one Tech Support (level 0) role per client
create unique index roles_one_owner on public.roles (tenant_id) where level = 1;
