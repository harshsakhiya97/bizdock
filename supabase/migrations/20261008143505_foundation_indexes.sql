create index if not exists member_businesses_business_tenant_idx on public.member_businesses (business_id, tenant_id);
create index if not exists member_businesses_member_tenant_idx on public.member_businesses (member_id, tenant_id);
create index if not exists tenant_members_role_tenant_idx on public.tenant_members (role_id, tenant_id);
