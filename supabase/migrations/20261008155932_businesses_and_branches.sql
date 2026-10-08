-- ============================================================
-- Businesses: details + archive.  Branches: per business.
-- Deleting in the app = archiving (is_active = false); data is kept.
-- ============================================================

alter table public.businesses
  add column logo_url      text,
  add column phone         text,
  add column email         text,
  add column address       text,
  add column city          text,
  add column state         text,
  add column gst_number    text,
  add column legal_name    text,
  add column has_branches  boolean not null default false,
  add column archived_at   timestamptz;

create table public.branches (
  id                 uuid primary key default gen_random_uuid(),
  tenant_id          uuid not null references public.tenants (id) on delete cascade,
  business_id        uuid not null,
  name               text not null,
  city               text,
  address            text,
  phone              text,
  email              text,
  manager_member_id  uuid references public.tenant_members (id) on delete set null,
  is_active          boolean not null default true,
  archived_at        timestamptz,
  sort_order         int not null default 0,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  unique (id, tenant_id),
  unique (id, business_id),
  foreign key (business_id, tenant_id) references public.businesses (id, tenant_id) on delete cascade
);
create index branches_business_idx on public.branches (business_id, tenant_id);
create index branches_tenant_idx on public.branches (tenant_id);
create index branches_manager_idx on public.branches (manager_member_id);
create trigger branches_set_updated_at before update on public.branches
  for each row execute function public.set_updated_at();

-- Businesses are now governed by the 'businesses' permission module
alter policy "businesses: read" on public.businesses
  using (private.can_access_business(id) or private.has_permission(tenant_id, 'businesses', 'view'));
alter policy "businesses: insert" on public.businesses
  with check (private.has_permission(tenant_id, 'businesses', 'add'));
alter policy "businesses: update" on public.businesses
  using (private.has_permission(tenant_id, 'businesses', 'edit'))
  with check (private.has_permission(tenant_id, 'businesses', 'edit'));
alter policy "businesses: delete" on public.businesses
  using (private.has_permission(tenant_id, 'businesses', 'delete'));

-- Branches follow their business
alter table public.branches enable row level security;
create policy "branches: read" on public.branches for select to authenticated
  using (private.can_access_business(business_id) or private.has_permission(tenant_id, 'businesses', 'view'));
create policy "branches: insert" on public.branches for insert to authenticated
  with check (private.has_permission(tenant_id, 'businesses', 'add') or private.has_permission(tenant_id, 'businesses', 'edit'));
create policy "branches: update" on public.branches for update to authenticated
  using (private.has_permission(tenant_id, 'businesses', 'edit'))
  with check (private.has_permission(tenant_id, 'businesses', 'edit'));
create policy "branches: delete" on public.branches for delete to authenticated
  using (private.has_permission(tenant_id, 'businesses', 'delete'));

grant select, insert, update, delete on public.branches to authenticated;
revoke all on public.branches from anon;

-- Business logos: public read; files live under <tenant_id>/...; editors of that tenant can write
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('business-logos', 'business-logos', true, 2097152,
        array['image/png','image/jpeg','image/webp','image/svg+xml'])
on conflict (id) do nothing;

create policy "business-logos: insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'business-logos'
              and private.has_permission(((storage.foldername(name))[1])::uuid, 'businesses', 'edit'));
create policy "business-logos: update" on storage.objects for update to authenticated
  using (bucket_id = 'business-logos'
         and private.has_permission(((storage.foldername(name))[1])::uuid, 'businesses', 'edit'));
create policy "business-logos: delete" on storage.objects for delete to authenticated
  using (bucket_id = 'business-logos'
         and private.has_permission(((storage.foldername(name))[1])::uuid, 'businesses', 'edit'));
