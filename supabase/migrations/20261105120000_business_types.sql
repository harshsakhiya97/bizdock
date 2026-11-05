-- Business types master: a name (editable, shown everywhere) and a code (set once, never changed).
-- The app's business-type rules go by the code (EDITING, PAID-PODCAST, STUDIO-RENTAL, …).
create table if not exists public.business_types (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  code text not null check (code ~ '^[A-Z0-9]+(-[A-Z0-9]+)*$' and length(code) <= 40),
  name text not null check (length(btrim(name)) between 1 and 80),
  is_system boolean not null default false,
  is_active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  unique (tenant_id, code)
);
alter table public.business_types enable row level security;
create policy "business_types: read" on public.business_types for select
  using (private.is_member(tenant_id) or private.is_platform_owner());
create policy "business_types: write" on public.business_types for all
  using (private.has_permission(tenant_id, 'masters', 'edit'))
  with check (private.has_permission(tenant_id, 'masters', 'edit'));

-- the code can't change; a built-in type or one in use can't be deleted
create or replace function private.business_types_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'UPDATE' then
    if new.code <> old.code or new.tenant_id <> old.tenant_id then
      raise exception 'A business type''s code can''t be changed.';
    end if;
    if old.is_system and not new.is_system then
      raise exception 'A built-in business type stays built-in.';
    end if;
    return new;
  end if;
  if old.is_system and exists (select 1 from public.tenants t where t.id = old.tenant_id) then
    raise exception 'A built-in business type can''t be deleted.';
  end if;
  if exists (select 1 from public.sub_businesses s where s.tenant_id = old.tenant_id and s.type = old.code)
     or exists (select 1 from public.businesses b where b.tenant_id = old.tenant_id and b.type = old.code) then
    raise exception 'This business type is in use; change those businesses first.';
  end if;
  return old;
end $$;
create trigger business_types_guard before update or delete on public.business_types
  for each row execute function private.business_types_guard();

-- every tenant gets the built-in types
create or replace function private.seed_business_types(t uuid) returns void
language sql security definer set search_path = '' as $$
  insert into public.business_types (tenant_id, code, name, is_system, sort_order) values
    (t, 'EDITING', 'Editing service', true, 1),
    (t, 'PAID-PODCAST', 'Podcast', true, 2),
    (t, 'STUDIO-RENTAL', 'Podcast studio rental', true, 3)
  on conflict (tenant_id, code) do nothing
$$;
create or replace function private.seed_new_tenant_business_types() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform private.seed_business_types(new.id);
  return new;
end $$;
create trigger tenants_seed_business_types after insert on public.tenants
  for each row execute function private.seed_new_tenant_business_types();
select private.seed_business_types(id) from public.tenants;

-- types are now any code from the master (old values keep working until they're moved over)
alter table public.sub_businesses drop constraint if exists sub_businesses_type_check;

create or replace function private.is_studio_sub(s uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.sub_businesses x where x.id = s
    and x.type in ('studio_rental', 'podcast', 'STUDIO-RENTAL', 'PAID-PODCAST'))
$$;

create or replace function public.studio_busy(p_business uuid, p_from date default null, p_to date default null)
returns table(id uuid, sub_business_id uuid, sub_name text, client_name text, purpose text, booking_date date, start_time time, end_time time, status text)
language sql stable security definer set search_path = '' as $$
  select b.id, b.sub_business_id, s.name, b.client_name, b.purpose, b.booking_date, b.start_time, b.end_time, b.status
    from public.bookings b join public.sub_businesses s on s.id = b.sub_business_id
   where b.business_id = p_business and private.can_access_business(p_business)
     and s.type in ('studio_rental', 'podcast', 'STUDIO-RENTAL', 'PAID-PODCAST') and b.status <> 'cancelled'
     and (p_from is null or b.booking_date >= p_from) and (p_to is null or b.booking_date <= p_to)
$$;
