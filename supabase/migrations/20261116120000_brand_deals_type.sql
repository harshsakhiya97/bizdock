-- Business type BRAND-DEALS ("Brand Deals"): works exactly like DEFAULT (orders, ORD numbers, invoice and payment parts,
-- customer once a part is paid). A system type of every workspace.
create or replace function private.is_default_biz(p_business uuid, p_sub uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select case when p_sub is not null
              then exists (select 1 from public.sub_businesses s where s.id = p_sub and s.type in ('DEFAULT', 'BRAND-DEALS'))
              else exists (select 1 from public.businesses b where b.id = p_business and b.type in ('DEFAULT', 'BRAND-DEALS')) end
$$;

create or replace function private.seed_business_types(t uuid) returns void
language sql security definer set search_path = '' as $$
  insert into public.business_types (tenant_id, code, name, is_system, sort_order) values
    (t, 'DEFAULT', 'Default', true, 0),
    (t, 'EDITING', 'Editing service', true, 1),
    (t, 'PAID-PODCAST', 'Podcast', true, 2),
    (t, 'STUDIO-RENTAL', 'Podcast studio rental', true, 3),
    (t, 'BRAND-DEALS', 'Brand Deals', true, 6)
  on conflict (tenant_id, code) do nothing
$$;
insert into public.business_types (tenant_id, code, name, is_system, sort_order)
select t.id, 'BRAND-DEALS', 'Brand Deals', true, 6 from public.tenants t
on conflict (tenant_id, code) do nothing;
