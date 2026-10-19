-- ============================================================
-- Sub-businesses: a business can be split into sub-businesses, each of a type
-- (editing service / podcast / podcast studio rental).
-- Leads, sales and bookings can belong to one sub-business of their business.
-- ============================================================

create table public.sub_businesses (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenants (id) on delete cascade,
  business_id  uuid not null,
  name         text not null check (length(trim(name)) > 0),
  type         text not null check (type in ('editing', 'podcast', 'studio_rental')),
  is_active    boolean not null default true,
  sort_order   int not null default 0,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (id, business_id),
  foreign key (business_id, tenant_id) references public.businesses (id, tenant_id) on delete cascade
);
create index sub_businesses_business_idx on public.sub_businesses (business_id, tenant_id);
create index sub_businesses_tenant_idx on public.sub_businesses (tenant_id);
create trigger sub_businesses_set_updated_at before update on public.sub_businesses
  for each row execute function public.set_updated_at();

alter table public.sub_businesses enable row level security;
create policy "sub_businesses: read" on public.sub_businesses for select to authenticated
  using (private.can_access_business(business_id) or private.has_permission(tenant_id, 'businesses', 'view'));
create policy "sub_businesses: insert" on public.sub_businesses for insert to authenticated
  with check (private.has_permission(tenant_id, 'businesses', 'add') or private.has_permission(tenant_id, 'businesses', 'edit'));
create policy "sub_businesses: update" on public.sub_businesses for update to authenticated
  using (private.has_permission(tenant_id, 'businesses', 'edit'))
  with check (private.has_permission(tenant_id, 'businesses', 'edit'));
create policy "sub_businesses: delete" on public.sub_businesses for delete to authenticated
  using (private.has_permission(tenant_id, 'businesses', 'delete') or private.has_permission(tenant_id, 'businesses', 'edit'));
grant select, insert, update, delete on public.sub_businesses to authenticated;
revoke all on public.sub_businesses from anon;

-- leads / sales / bookings: optional sub-business, which must belong to the row's business
alter table public.leads add column sub_business_id uuid;
alter table public.leads add constraint leads_sub_business_fk foreign key (sub_business_id, business_id)
  references public.sub_businesses (id, business_id) on delete set null (sub_business_id);
create index leads_sub_business_idx on public.leads (sub_business_id);

alter table public.sales add column sub_business_id uuid;
alter table public.sales add constraint sales_sub_business_fk foreign key (sub_business_id, business_id)
  references public.sub_businesses (id, business_id) on delete set null (sub_business_id);
create index sales_sub_business_idx on public.sales (sub_business_id);

alter table public.bookings add column sub_business_id uuid;
alter table public.bookings add constraint bookings_sub_business_fk foreign key (sub_business_id, business_id)
  references public.sub_businesses (id, business_id) on delete set null (sub_business_id);
create index bookings_sub_business_idx on public.bookings (sub_business_id);

-- create_sale(): also stores p->>'sub_business_id'
do $$
declare d text := pg_get_functiondef('public.create_sale'::regproc);
begin
  d := replace(d, '  sale        uuid;', E'  sale        uuid;\n  sub         uuid := nullif(p ->> ''sub_business_id'', '''')::uuid;');
  d := replace(d, 'insert into public.sales (id, tenant_id, business_id, customer_id,', 'insert into public.sales (id, tenant_id, business_id, sub_business_id, customer_id,');
  d := replace(d, 'values (sale, t, b, cust, lead,', 'values (sale, t, b, sub, cust, lead,');
  if d not like '%sub_business_id, customer_id%' or d not like '%sale, t, b, sub,%' then
    raise exception 'create_sale: patch did not apply';
  end if;
  execute d;
end $$;
