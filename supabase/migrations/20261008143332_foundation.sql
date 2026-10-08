-- ============================================================
-- BizDock foundation: platform owner, tenants, businesses,
-- roles & permissions, memberships, Tech Support Team, RLS
-- One shared database; every tenant row carries tenant_id.
-- ============================================================

-- ---------- profiles: role now lives on per-tenant memberships ----------
-- (the old profiles.role column is no longer used; dropped in a later cleanup migration)

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id, email, full_name)
  values (new.id, new.email,
          coalesce(new.raw_user_meta_data ->> 'full_name', split_part(new.email, '@', 1)));
  return new;
end;
$$;

-- ---------- platform owners (admin.bizdock.in) ----------
create table public.platform_owners (
  user_id    uuid primary key references auth.users (id) on delete cascade,
  created_at timestamptz not null default now()
);

-- ---------- tenants (registry + branding) ----------
create table public.tenants (
  id               uuid primary key default gen_random_uuid(),
  name             text not null,
  tenant_key       text not null unique
                     default 'tk_' || encode(extensions.gen_random_bytes(8), 'hex'),
  app_name         text not null,
  logo_url         text,
  favicon_url      text,
  primary_color    text not null default '#2b5fe8',
  status           text not null default 'active' check (status in ('active', 'suspended')),
  plan             text,
  enabled_modules  text[] not null default '{}',
  -- Registry: null = shared BizDock database. Set both to move a tenant to its own Supabase project.
  supabase_url     text,
  supabase_key     text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create trigger tenants_set_updated_at before update on public.tenants
  for each row execute function public.set_updated_at();

create table public.tenant_domains (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.tenants (id) on delete cascade,
  domain     text not null unique check (domain = lower(domain)),
  is_primary boolean not null default false,
  created_at timestamptz not null default now()
);
create index on public.tenant_domains (tenant_id);

-- ---------- businesses ----------
create table public.businesses (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.tenants (id) on delete cascade,
  name       text not null,
  is_active  boolean not null default true,
  sort_order int not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, tenant_id)
);
create index on public.businesses (tenant_id);
create trigger businesses_set_updated_at before update on public.businesses
  for each row execute function public.set_updated_at();

-- ---------- roles (defined by each tenant) ----------
-- permissions: { "<module>": { "view": bool, "add": bool, "edit": bool, "delete": bool }, ... }
create table public.roles (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenants (id) on delete cascade,
  name        text not null,
  description text,
  permissions jsonb not null default '{}',
  is_system   boolean not null default false,   -- Tech Support Team: tenants can't edit/delete
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (tenant_id, name),
  unique (id, tenant_id)
);
create trigger roles_set_updated_at before update on public.roles
  for each row execute function public.set_updated_at();

-- ---------- memberships ----------
create table public.tenant_members (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references public.tenants (id) on delete cascade,
  user_id        uuid not null references auth.users (id) on delete cascade,
  role_id        uuid not null,
  all_businesses boolean not null default false,
  is_support     boolean not null default false,  -- Tech Support Team: tenants can't remove
  status         text not null default 'active' check (status in ('active', 'disabled')),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  unique (tenant_id, user_id),
  unique (id, tenant_id),
  foreign key (role_id, tenant_id) references public.roles (id, tenant_id)
);
create index on public.tenant_members (user_id);
create trigger tenant_members_set_updated_at before update on public.tenant_members
  for each row execute function public.set_updated_at();

create table public.member_businesses (
  member_id   uuid not null,
  business_id uuid not null,
  tenant_id   uuid not null,
  primary key (member_id, business_id),
  foreign key (member_id, tenant_id) references public.tenant_members (id, tenant_id) on delete cascade,
  foreign key (business_id, tenant_id) references public.businesses (id, tenant_id) on delete cascade
);
create index on public.member_businesses (business_id);

-- ============================================================
-- Helper functions (private schema, not exposed over the API)
-- ============================================================
create schema if not exists private;
revoke all on schema private from public, anon;
grant usage on schema private to authenticated;

create or replace function private.is_platform_owner()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.platform_owners where user_id = (select auth.uid()))
$$;

create or replace function private.is_member(t uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.tenant_members
    where tenant_id = t and user_id = (select auth.uid()) and status = 'active'
  )
$$;

create or replace function private.has_permission(t uuid, module text, action text)
returns boolean language sql stable security definer set search_path = '' as $$
  select private.is_platform_owner() or exists (
    select 1
    from public.tenant_members m
    join public.roles r on r.id = m.role_id
    where m.tenant_id = t and m.user_id = (select auth.uid()) and m.status = 'active'
      and coalesce((r.permissions -> module ->> action)::boolean, false)
  )
$$;

create or replace function private.can_access_business(b uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select private.is_platform_owner() or exists (
    select 1
    from public.businesses bz
    join public.tenant_members m on m.tenant_id = bz.tenant_id
    where bz.id = b and m.user_id = (select auth.uid()) and m.status = 'active'
      and (m.all_businesses
           or exists (select 1 from public.member_businesses mb where mb.member_id = m.id and mb.business_id = b))
  )
$$;

create or replace function private.shares_tenant(other uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.tenant_members a
    join public.tenant_members b on b.tenant_id = a.tenant_id
    where a.user_id = (select auth.uid()) and a.status = 'active' and b.user_id = other
  )
$$;

revoke execute on all functions in schema private from public, anon;
grant execute on all functions in schema private to authenticated;

-- Permission set builder used for starter roles
create or replace function private.perms(modules text[], v boolean, a boolean, e boolean, d boolean)
returns jsonb language sql immutable set search_path = '' as $$
  select coalesce(jsonb_object_agg(m, jsonb_build_object('view', v, 'add', a, 'edit', e, 'delete', d)), '{}'::jsonb)
  from unnest(modules) as m
$$;

-- ============================================================
-- New tenant: starter roles + Tech Support Team membership
-- ============================================================
create or replace function private.seed_new_tenant()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  all_modules constant text[] := array['dashboard','leads','pipelines','follow_ups','calling',
                                       'funnels','payments','finance','team','settings'];
  support_role uuid;
begin
  insert into public.roles (tenant_id, name, description, permissions, is_system)
  values (new.id, 'Tech Support Team', 'BizDock support. Full access; cannot be edited or removed.',
          private.perms(all_modules, true, true, true, true), true)
  returning id into support_role;

  insert into public.roles (tenant_id, name, description, permissions) values
    (new.id, 'Admin', 'Full access to everything, including team and settings.',
       private.perms(all_modules, true, true, true, true)),
    (new.id, 'Business Manager', 'Runs day-to-day sales for the businesses they are given.',
       private.perms(array['dashboard','team','finance'], true, false, false, false)
       || private.perms(array['leads','pipelines','follow_ups','calling','funnels'], true, true, true, false)
       || private.perms(array['payments'], true, true, false, false)),
    (new.id, 'Caller', 'Calls leads and logs outcomes.',
       private.perms(array['dashboard'], true, false, false, false)
       || private.perms(array['leads'], true, false, true, false)
       || private.perms(array['follow_ups','calling'], true, true, true, false)),
    (new.id, 'Accounts', 'Handles payments, income and expenses.',
       private.perms(array['dashboard','leads'], true, false, false, false)
       || private.perms(array['payments','finance'], true, true, true, true));

  insert into public.tenant_members (tenant_id, user_id, role_id, all_businesses, is_support)
  select new.id, po.user_id, support_role, true, true from public.platform_owners po;

  return new;
end;
$$;

create trigger tenants_seed after insert on public.tenants
  for each row execute function private.seed_new_tenant();

-- ---------- guards: tenants can't touch Tech Support Team ----------
create or replace function private.guard_system_role()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  -- server-side (SQL editor, service role) and the platform owner are always allowed
  if (select auth.uid()) is null or private.is_platform_owner() then
    return coalesce(new, old);
  end if;
  if tg_op = 'INSERT' and new.is_system then
    raise exception 'Only BizDock can create system roles';
  end if;
  if tg_op in ('UPDATE', 'DELETE') and old.is_system then
    raise exception 'The Tech Support Team role cannot be changed or deleted';
  end if;
  if tg_op = 'UPDATE' and new.is_system then
    raise exception 'Only BizDock can create system roles';
  end if;
  return coalesce(new, old);
end;
$$;

create trigger roles_guard before insert or update or delete on public.roles
  for each row execute function private.guard_system_role();

create or replace function private.guard_support_member()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  -- server-side (SQL editor, service role) and the platform owner are always allowed
  if (select auth.uid()) is null or private.is_platform_owner() then
    return coalesce(new, old);
  end if;
  if tg_op in ('UPDATE', 'DELETE') and old.is_support then
    raise exception 'The Tech Support Team member cannot be changed or removed';
  end if;
  if tg_op in ('INSERT', 'UPDATE') then
    if new.is_support then
      raise exception 'Only BizDock can add Tech Support Team members';
    end if;
    if exists (select 1 from public.roles where id = new.role_id and is_system) then
      raise exception 'The Tech Support Team role is reserved for BizDock';
    end if;
  end if;
  return coalesce(new, old);
end;
$$;

create trigger tenant_members_guard before insert or update or delete on public.tenant_members
  for each row execute function private.guard_support_member();

-- ============================================================
-- Public tenant lookup (before login): domain or tenant key -> branding
-- Returns only public branding fields of active tenants.
-- ============================================================
create or replace function public.resolve_tenant(p_domain text default null, p_key text default null)
returns table (
  id uuid, name text, app_name text, logo_url text, favicon_url text,
  primary_color text, supabase_url text, supabase_key text
)
language sql stable security definer set search_path = '' as $$
  select t.id, t.name, t.app_name, t.logo_url, t.favicon_url, t.primary_color, t.supabase_url, t.supabase_key
  from public.tenants t
  where t.status = 'active'
    and (
      (p_key is not null and t.tenant_key = p_key)
      or (p_domain is not null and exists (
            select 1 from public.tenant_domains d where d.tenant_id = t.id and d.domain = lower(p_domain)))
    )
  limit 1
$$;
revoke execute on function public.resolve_tenant(text, text) from public;
grant execute on function public.resolve_tenant(text, text) to anon, authenticated;

-- ============================================================
-- Row Level Security
-- ============================================================
alter table public.platform_owners   enable row level security;
alter table public.tenants           enable row level security;
alter table public.tenant_domains    enable row level security;
alter table public.businesses        enable row level security;
alter table public.roles             enable row level security;
alter table public.tenant_members    enable row level security;
alter table public.member_businesses enable row level security;

-- platform_owners: you can only see whether you yourself are an owner
create policy "owners: read self" on public.platform_owners for select to authenticated
  using (user_id = (select auth.uid()));

-- tenants & domains: members read; only the platform owner writes
create policy "tenants: read" on public.tenants for select to authenticated
  using (private.is_platform_owner() or private.is_member(id));
create policy "tenants: owner insert" on public.tenants for insert to authenticated
  with check (private.is_platform_owner());
create policy "tenants: owner update" on public.tenants for update to authenticated
  using (private.is_platform_owner()) with check (private.is_platform_owner());
create policy "tenants: owner delete" on public.tenants for delete to authenticated
  using (private.is_platform_owner());

create policy "domains: read" on public.tenant_domains for select to authenticated
  using (private.is_platform_owner() or private.is_member(tenant_id));
create policy "domains: owner insert" on public.tenant_domains for insert to authenticated
  with check (private.is_platform_owner());
create policy "domains: owner update" on public.tenant_domains for update to authenticated
  using (private.is_platform_owner()) with check (private.is_platform_owner());
create policy "domains: owner delete" on public.tenant_domains for delete to authenticated
  using (private.is_platform_owner());

-- businesses: see the ones you have access to; settings permission to manage
create policy "businesses: read" on public.businesses for select to authenticated
  using (private.can_access_business(id) or private.has_permission(tenant_id, 'settings', 'view'));
create policy "businesses: insert" on public.businesses for insert to authenticated
  with check (private.has_permission(tenant_id, 'settings', 'add'));
create policy "businesses: update" on public.businesses for update to authenticated
  using (private.has_permission(tenant_id, 'settings', 'edit'))
  with check (private.has_permission(tenant_id, 'settings', 'edit'));
create policy "businesses: delete" on public.businesses for delete to authenticated
  using (private.has_permission(tenant_id, 'settings', 'delete'));

-- roles: members read their tenant's roles; team permission to manage
create policy "roles: read" on public.roles for select to authenticated
  using (private.is_platform_owner() or private.is_member(tenant_id));
create policy "roles: insert" on public.roles for insert to authenticated
  with check (private.has_permission(tenant_id, 'team', 'add'));
create policy "roles: update" on public.roles for update to authenticated
  using (private.has_permission(tenant_id, 'team', 'edit'))
  with check (private.has_permission(tenant_id, 'team', 'edit'));
create policy "roles: delete" on public.roles for delete to authenticated
  using (private.has_permission(tenant_id, 'team', 'delete'));

-- members: see your own row, or everyone if you can view the team
create policy "members: read" on public.tenant_members for select to authenticated
  using (user_id = (select auth.uid()) or private.has_permission(tenant_id, 'team', 'view'));
create policy "members: insert" on public.tenant_members for insert to authenticated
  with check (private.has_permission(tenant_id, 'team', 'add'));
create policy "members: update" on public.tenant_members for update to authenticated
  using (private.has_permission(tenant_id, 'team', 'edit'))
  with check (private.has_permission(tenant_id, 'team', 'edit'));
create policy "members: delete" on public.tenant_members for delete to authenticated
  using (private.has_permission(tenant_id, 'team', 'delete'));

create policy "member_businesses: read" on public.member_businesses for select to authenticated
  using (private.has_permission(tenant_id, 'team', 'view')
         or exists (select 1 from public.tenant_members m where m.id = member_id and m.user_id = (select auth.uid())));
create policy "member_businesses: insert" on public.member_businesses for insert to authenticated
  with check (private.has_permission(tenant_id, 'team', 'edit'));
create policy "member_businesses: delete" on public.member_businesses for delete to authenticated
  using (private.has_permission(tenant_id, 'team', 'edit'));

-- profiles: also readable by people you share a tenant with, and by the platform owner
create policy "profiles: read teammates" on public.profiles for select to authenticated
  using (private.is_platform_owner() or private.shares_tenant(id));

-- table privileges for the API roles
grant select, insert, update, delete on
  public.tenants, public.tenant_domains, public.businesses, public.roles,
  public.tenant_members, public.member_businesses to authenticated;
grant select on public.platform_owners to authenticated;
revoke all on
  public.tenants, public.tenant_domains, public.businesses, public.roles,
  public.tenant_members, public.member_businesses, public.platform_owners from anon;
