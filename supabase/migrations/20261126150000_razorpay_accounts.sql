-- Razorpay: as many accounts per workspace as needed (like Zoom), each with its own name; payments keep their integration_id.
drop index if exists public.integrations_one_per_provider;
create unique index integrations_one_per_provider on public.integrations (tenant_id, provider) where provider <> all (array['facebook_ads', 'zoom', 'razorpay']);
create unique index if not exists integrations_razorpay_name on public.integrations (tenant_id, lower(label)) where provider = 'razorpay' and label is not null;

-- the Razorpay account names (Payments → Razorpay: Account column and filter); only names, no keys
create or replace function public.razorpay_accounts(p_tenant uuid)
returns table(id uuid, label text)
language sql stable security definer set search_path = '' as $$
  select i.id, coalesce(i.label, 'Razorpay') from public.integrations i
   where i.tenant_id = p_tenant and i.provider = 'razorpay'
     and (private.has_permission(p_tenant, 'payments', 'view') or private.has_permission(p_tenant, 'funnels', 'view')
          or private.has_permission(p_tenant, 'leads', 'view') or private.has_permission(p_tenant, 'settings', 'view'))
   order by i.connected_at
$$;
revoke all on function public.razorpay_accounts(uuid) from public, anon;
grant execute on function public.razorpay_accounts(uuid) to authenticated;
