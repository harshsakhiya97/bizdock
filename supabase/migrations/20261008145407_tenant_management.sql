-- Tenant branding files (logos, favicons). Public read; only the platform owner can upload/change.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('tenant-branding', 'tenant-branding', true, 2097152,
        array['image/png','image/jpeg','image/webp','image/svg+xml','image/x-icon','image/vnd.microsoft.icon'])
on conflict (id) do nothing;

create policy "tenant-branding: owner insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'tenant-branding' and private.is_platform_owner());
create policy "tenant-branding: owner update" on storage.objects for update to authenticated
  using (bucket_id = 'tenant-branding' and private.is_platform_owner());
create policy "tenant-branding: owner delete" on storage.objects for delete to authenticated
  using (bucket_id = 'tenant-branding' and private.is_platform_owner());

-- At most one primary domain per tenant
create unique index tenant_domains_one_primary on public.tenant_domains (tenant_id) where is_primary;

-- Own-database registry: set both URL and key, or neither
alter table public.tenants add constraint tenants_registry_pair
  check ((supabase_url is null) = (supabase_key is null));
