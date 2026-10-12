-- ============================================================
-- Masters (products, billing companies, payment modes, customer stages)
-- + Customers, Sales (full / booking / EMI), dues and payments.
--
-- Who sees what:
--   customers  → "Customers" visibility, by the customer's owner
--   sales      → "Sales, payments & collections" visibility, by the sales person
-- Permissions: deals.add (new sale), deals.edit (edit / cancel a sale),
--   customers.edit (edit / archive customers), payments.view / payments.add,
--   masters.edit (all master lists).
-- Deleting in the app = archiving / deactivating; data is kept.
-- ============================================================

-- ---------- masters ----------
create table public.products (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references public.tenants (id) on delete cascade,
  business_id      uuid not null,
  name             text not null,
  code             text,
  description      text,
  category         text,
  price            numeric(12, 2) not null default 0,       -- before GST
  gst_applicable   boolean not null default true,
  gst_rate         numeric(5, 2) not null default 18,
  lifetime         boolean not null default false,
  validity_months  int check (validity_months is null or validity_months > 0),
  is_active        boolean not null default true,
  sort_order       int not null default 0,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  foreign key (business_id, tenant_id) references public.businesses (id, tenant_id) on delete cascade
);
create index products_tenant_idx on public.products (tenant_id, business_id, sort_order);
create trigger products_set_updated_at before update on public.products
  for each row execute function public.set_updated_at();

create table public.billing_companies (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenants (id) on delete cascade,
  name            text not null,             -- short name shown in lists
  legal_name      text,
  gst_number      text,
  address         text,
  state           text,
  invoice_prefix  text,
  is_active       boolean not null default true,
  sort_order      int not null default 0,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index billing_companies_tenant_idx on public.billing_companies (tenant_id, sort_order);
create trigger billing_companies_set_updated_at before update on public.billing_companies
  for each row execute function public.set_updated_at();

create table public.payment_modes (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenants (id) on delete cascade,
  name        text not null,
  is_active   boolean not null default true,
  sort_order  int not null default 0,
  created_at  timestamptz not null default now(),
  unique (tenant_id, name)
);

create table public.customer_stages (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenants (id) on delete cascade,
  name        text not null,
  color       text not null default '#64748b',
  is_active   boolean not null default true,
  sort_order  int not null default 0,
  created_at  timestamptz not null default now(),
  unique (tenant_id, name)
);

create or replace function private.seed_sales_masters(t uuid)
returns void language sql security definer set search_path = '' as $$
  insert into public.payment_modes (tenant_id, name, sort_order)
  select t, s.name, s.ord from unnest(array[
    'UPI', 'Cash', 'Bank transfer', 'Razorpay', 'Card', 'Cheque', 'Other'
  ]) with ordinality as s(name, ord)
  on conflict do nothing;
  insert into public.customer_stages (tenant_id, name, color, sort_order)
  select t, s.name, s.color, s.ord from unnest(
    array['Onboarding', 'Activation', 'Active', 'Result', 'Upsell', 'Feedback'],
    array['#8b5cf6', '#3b82f6', '#16a34a', '#0d9488', '#ea580c', '#d97706']
  ) with ordinality as s(name, color, ord)
  on conflict do nothing;
$$;
create or replace function private.seed_new_tenant_sales_masters()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform private.seed_sales_masters(new.id);
  return new;
end;
$$;
create trigger tenants_seed_sales_masters after insert on public.tenants
  for each row execute function private.seed_new_tenant_sales_masters();
select private.seed_sales_masters(id) from public.tenants;

-- ---------- customers ----------
create table public.customers (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenants (id) on delete cascade,
  business_id   uuid not null,
  lead_id       uuid references public.leads (id) on delete set null,
  full_name     text not null,
  phone         text,
  email         text,
  city          text,
  stage_id      uuid references public.customer_stages (id) on delete set null,
  owner_id      uuid references public.tenant_members (id) on delete set null,
  notes         text,
  is_archived   boolean not null default false,
  archived_at   timestamptz,
  created_by    uuid references public.tenant_members (id) on delete set null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  foreign key (business_id, tenant_id) references public.businesses (id, tenant_id) on delete cascade
);
create index customers_tenant_idx on public.customers (tenant_id, created_at desc);
create index customers_business_phone_idx on public.customers (business_id, phone);
create index customers_owner_idx on public.customers (owner_id);
create trigger customers_set_updated_at before update on public.customers
  for each row execute function public.set_updated_at();

-- ---------- sales ----------
create table public.sales (
  id                  uuid primary key default gen_random_uuid(),
  tenant_id           uuid not null references public.tenants (id) on delete cascade,
  business_id         uuid not null,
  customer_id         uuid not null references public.customers (id) on delete cascade,
  lead_id             uuid references public.leads (id) on delete set null,
  product_id          uuid not null references public.products (id),
  billing_company_id  uuid not null references public.billing_companies (id),
  quantity            int not null default 1 check (quantity > 0),
  plan                text not null check (plan in ('full', 'booking', 'emi')),
  base_amount         numeric(12, 2) not null check (base_amount >= 0),   -- before GST, all units
  gst_applicable      boolean not null default true,
  gst_rate            numeric(5, 2) not null default 0,
  gst_amount          numeric(12, 2) not null default 0,
  total_amount        numeric(12, 2) not null,
  paid_amount         numeric(12, 2) not null default 0,                  -- kept by trigger from payments
  sale_date           date not null default current_date,
  valid_until         date,                                               -- null = lifetime / no validity
  sales_person_id     uuid references public.tenant_members (id) on delete set null,
  payment_mode_id     uuid references public.payment_modes (id) on delete set null,
  reference           text,                                               -- UTR / Razorpay / ref no.
  payment_remark      text,
  notes               text,
  status              text not null default 'active' check (status in ('active', 'cancelled')),
  cancel_reason       text,
  cancelled_at        timestamptz,
  created_by          uuid references public.tenant_members (id) on delete set null,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  foreign key (business_id, tenant_id) references public.businesses (id, tenant_id) on delete cascade
);
create index sales_tenant_idx on public.sales (tenant_id, sale_date desc);
create index sales_customer_idx on public.sales (customer_id);
create index sales_person_idx on public.sales (sales_person_id);
create trigger sales_set_updated_at before update on public.sales
  for each row execute function public.set_updated_at();

-- what is still to be collected: a booking balance, or each EMI instalment
create table public.sale_dues (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenants (id) on delete cascade,
  sale_id      uuid not null references public.sales (id) on delete cascade,
  kind         text not null check (kind in ('balance', 'emi')),
  seq          int not null default 1,
  due_on       date not null,
  amount       numeric(12, 2) not null check (amount > 0),
  paid_amount  numeric(12, 2) not null default 0,
  status       text not null default 'pending' check (status in ('pending', 'paid', 'cancelled')),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index sale_dues_sale_idx on public.sale_dues (sale_id, seq);
create index sale_dues_tenant_due_idx on public.sale_dues (tenant_id, status, due_on);
create trigger sale_dues_set_updated_at before update on public.sale_dues
  for each row execute function public.set_updated_at();

create table public.payments (
  id                  uuid primary key default gen_random_uuid(),
  tenant_id           uuid not null references public.tenants (id) on delete cascade,
  sale_id             uuid not null references public.sales (id) on delete cascade,
  customer_id         uuid not null references public.customers (id) on delete cascade,
  amount              numeric(12, 2) not null check (amount > 0),
  paid_on             date not null default current_date,
  payment_mode_id     uuid references public.payment_modes (id) on delete set null,
  billing_company_id  uuid references public.billing_companies (id) on delete set null,
  reference           text,
  note                text,
  status              text not null default 'received' check (status in ('received', 'cancelled')),
  received_by         uuid references public.tenant_members (id) on delete set null,
  created_at          timestamptz not null default now()
);
create index payments_sale_idx on public.payments (sale_id);
create index payments_tenant_idx on public.payments (tenant_id, paid_on desc);

-- sales.paid_amount = everything received on it
create or replace function private.sync_sale_paid()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  sid uuid := coalesce(new.sale_id, old.sale_id);
begin
  update public.sales s
  set paid_amount = coalesce((select sum(p.amount) from public.payments p where p.sale_id = sid and p.status = 'received'), 0)
  where s.id = sid;
  return null;
end;
$$;
create trigger payments_sync_sale after insert or update or delete on public.payments
  for each row execute function private.sync_sale_paid();

-- ============================================================
-- Visibility helpers (same rules as leads, for any area)
-- ============================================================
create or replace function private.area_scope(t uuid, area text)
returns text language sql stable security definer set search_path = '' as $$
  select case
    when private.is_platform_owner() then 'all'
    else (
      select case
        when r.is_system or r.level <= 1 then 'all'
        else coalesce(coalesce(m.permissions, r.permissions) -> 'scope' ->> area, 'none')
      end
      from public.tenant_members m join public.roles r on r.id = m.role_id
      where m.tenant_id = t and m.user_id = (select auth.uid()) and m.status = 'active'
    )
  end
$$;

create or replace function private.can_see_owned(t uuid, b uuid, owner uuid, area text)
returns boolean language sql stable security definer set search_path = '' as $$
  select private.can_access_business(b) and case private.area_scope(t, area)
    when 'all'  then true
    when 'team' then owner is null or owner in (select private.my_team(t))
    when 'own'  then owner = private.my_member_id(t)
    else false
  end
$$;

create or replace function private.can_see_sale(s uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.sales x where x.id = s
                 and private.can_see_owned(x.tenant_id, x.business_id, x.sales_person_id, 'sales'))
$$;

-- an existing (non-archived) customer of this business with the same phone (last 10 digits)
create or replace function private.find_customer(b uuid, p_phone text)
returns uuid language sql stable security definer set search_path = '' as $$
  select c.id from public.customers c
  where private.can_access_business(b) and c.business_id = b and not c.is_archived
    and coalesce(p_phone, '') <> ''
    and right(regexp_replace(c.phone, '\D', '', 'g'), 10) = right(regexp_replace(p_phone, '\D', '', 'g'), 10)
  order by c.created_at
  limit 1
$$;

revoke execute on all functions in schema private from public, anon;
grant execute on all functions in schema private to authenticated;

-- ============================================================
-- Row security
-- ============================================================
alter table public.products enable row level security;
create policy "products: read" on public.products for select to authenticated
  using (private.is_member(tenant_id) or private.is_platform_owner());
create policy "products: write" on public.products for all to authenticated
  using (private.has_permission(tenant_id, 'masters', 'edit'))
  with check (private.has_permission(tenant_id, 'masters', 'edit'));

alter table public.billing_companies enable row level security;
create policy "billing_companies: read" on public.billing_companies for select to authenticated
  using (private.is_member(tenant_id) or private.is_platform_owner());
create policy "billing_companies: write" on public.billing_companies for all to authenticated
  using (private.has_permission(tenant_id, 'masters', 'edit'))
  with check (private.has_permission(tenant_id, 'masters', 'edit'));

alter table public.payment_modes enable row level security;
create policy "payment_modes: read" on public.payment_modes for select to authenticated
  using (private.is_member(tenant_id) or private.is_platform_owner());
create policy "payment_modes: write" on public.payment_modes for all to authenticated
  using (private.has_permission(tenant_id, 'masters', 'edit'))
  with check (private.has_permission(tenant_id, 'masters', 'edit'));

alter table public.customer_stages enable row level security;
create policy "customer_stages: read" on public.customer_stages for select to authenticated
  using (private.is_member(tenant_id) or private.is_platform_owner());
create policy "customer_stages: write" on public.customer_stages for all to authenticated
  using (private.has_permission(tenant_id, 'masters', 'edit'))
  with check (private.has_permission(tenant_id, 'masters', 'edit'));

alter table public.customers enable row level security;
create policy "customers: read" on public.customers for select to authenticated
  using (private.can_see_owned(tenant_id, business_id, owner_id, 'customers'));
create policy "customers: insert" on public.customers for insert to authenticated
  with check ((private.has_permission(tenant_id, 'deals', 'add') or private.has_permission(tenant_id, 'customers', 'edit'))
              and private.can_access_business(business_id));
create policy "customers: update" on public.customers for update to authenticated
  using (private.has_permission(tenant_id, 'customers', 'edit')
         and private.can_see_owned(tenant_id, business_id, owner_id, 'customers'))
  with check (private.can_access_business(business_id));

alter table public.sales enable row level security;
create policy "sales: read" on public.sales for select to authenticated
  using (private.can_see_owned(tenant_id, business_id, sales_person_id, 'sales'));
create policy "sales: insert" on public.sales for insert to authenticated
  with check (private.has_permission(tenant_id, 'deals', 'add') and private.can_access_business(business_id));
create policy "sales: update" on public.sales for update to authenticated
  using (private.has_permission(tenant_id, 'deals', 'edit')
         and private.can_see_owned(tenant_id, business_id, sales_person_id, 'sales'))
  with check (private.can_access_business(business_id));

alter table public.sale_dues enable row level security;
create policy "sale_dues: read" on public.sale_dues for select to authenticated
  using (private.can_see_sale(sale_id));
create policy "sale_dues: insert" on public.sale_dues for insert to authenticated
  with check ((private.has_permission(tenant_id, 'deals', 'add') or private.has_permission(tenant_id, 'deals', 'edit'))
              and private.can_see_sale(sale_id));
create policy "sale_dues: update" on public.sale_dues for update to authenticated
  using ((private.has_permission(tenant_id, 'deals', 'edit') or private.has_permission(tenant_id, 'payments', 'add'))
         and private.can_see_sale(sale_id))
  with check (true);

alter table public.payments enable row level security;
create policy "payments: read" on public.payments for select to authenticated
  using (private.can_see_sale(sale_id));
create policy "payments: insert" on public.payments for insert to authenticated
  with check ((private.has_permission(tenant_id, 'payments', 'add') or private.has_permission(tenant_id, 'deals', 'add'))
              and private.can_see_sale(sale_id));
create policy "payments: update" on public.payments for update to authenticated
  using ((private.has_permission(tenant_id, 'payments', 'verify') or private.has_permission(tenant_id, 'deals', 'edit'))
         and private.can_see_sale(sale_id))
  with check (true);

grant select, insert, update, delete on public.products, public.billing_companies, public.payment_modes, public.customer_stages to authenticated;
grant select, insert, update on public.customers, public.sales, public.sale_dues, public.payments to authenticated;


-- ============================================================
-- New sale: one call creates (or finds) the customer, the sale, the first payment and the dues.
-- Runs with the caller's rights, so row security decides.
-- ============================================================
create or replace function public.create_sale(p jsonb)
returns uuid
language plpgsql security invoker set search_path = '' as $$
declare
  t           uuid := (p ->> 'tenant_id')::uuid;
  b           uuid := (p ->> 'business_id')::uuid;
  me          uuid := private.my_member_id(t);
  cust        uuid := nullif(p ->> 'customer_id', '')::uuid;
  lead        uuid := nullif(p ->> 'lead_id', '')::uuid;
  person      uuid := coalesce(nullif(p ->> 'sales_person_id', '')::uuid, me);
  prod        public.products%rowtype;
  plan        text := p ->> 'plan';
  qty         int := greatest(coalesce((p ->> 'quantity')::int, 1), 1);
  base        numeric := round(coalesce((p ->> 'base_amount')::numeric, -1), 2);
  gst_on      boolean := coalesce((p ->> 'gst_applicable')::boolean, true);
  rate        numeric := case when coalesce((p ->> 'gst_applicable')::boolean, true) then coalesce((p ->> 'gst_rate')::numeric, 0) else 0 end;
  gst         numeric;
  total       numeric;
  sdate       date := coalesce(nullif(p ->> 'sale_date', '')::date, current_date);
  paid_now    numeric;
  balance_on  date := nullif(p ->> 'balance_due_on', '')::date;
  n           int := coalesce(nullif(p ->> 'emi_count', '')::int, 0);
  first_on    date := nullif(p ->> 'first_emi_on', '')::date;
  each_amt    numeric;
  rest        numeric;
  sale        uuid;
  first_stage uuid;
  i           int;
begin
  if me is null then raise exception 'You are not part of this workspace.'; end if;
  if plan not in ('full', 'booking', 'emi') then raise exception 'Pick a payment plan.'; end if;
  if base < 0 then raise exception 'Enter the amount before GST.'; end if;

  select * into prod from public.products where id = (p ->> 'product_id')::uuid and tenant_id = t;
  if prod.id is null then raise exception 'Pick a product.'; end if;
  if prod.business_id <> b then raise exception 'This product belongs to another business.'; end if;
  if not exists (select 1 from public.billing_companies where id = (p ->> 'billing_company_id')::uuid and tenant_id = t) then
    raise exception 'Pick a billing company.';
  end if;

  gst := round(base * rate / 100, 2);
  total := base + gst;
  paid_now := round(case plan
    when 'full'    then coalesce(nullif(p ->> 'received_now', '')::numeric, total)
    when 'booking' then coalesce(nullif(p ->> 'token_amount', '')::numeric, 0)
    else                coalesce(nullif(p ->> 'down_payment', '')::numeric, 0)
  end, 2);
  if paid_now < 0 or paid_now > total then raise exception 'The amount received can’t be more than the total (%).', total; end if;
  if plan = 'booking' then
    if paid_now <= 0 then raise exception 'Enter the token amount received.'; end if;
    if paid_now >= total then raise exception 'For a booking the token must be less than the total. Use Full payment instead.'; end if;
    if balance_on is null then raise exception 'Enter the date the balance is promised.'; end if;
  end if;
  if plan = 'emi' then
    if n < 1 then raise exception 'Enter the number of instalments.'; end if;
    if first_on is null then raise exception 'Enter the first instalment date.'; end if;
    if paid_now >= total then raise exception 'The down payment covers the full amount. Use Full payment instead.'; end if;
  end if;
  if plan = 'full' and paid_now < total and balance_on is null then
    raise exception 'Enter when the remaining amount will be paid.';
  end if;

  -- customer: picked, or the same phone in this business, or a new one
  if cust is null then
    cust := private.find_customer(b, p -> 'customer' ->> 'phone');
  end if;
  if cust is null then
    if coalesce(trim(p -> 'customer' ->> 'full_name'), '') = '' then raise exception 'Enter the customer’s name.'; end if;
    select id into first_stage from public.customer_stages where tenant_id = t and is_active order by sort_order limit 1;
    -- ids are made here (no RETURNING): the caller may create rows they can't read back
    cust := gen_random_uuid();
    insert into public.customers (id, tenant_id, business_id, lead_id, full_name, phone, email, city, stage_id, owner_id, notes, created_by)
    values (cust, t, b, lead, trim(p -> 'customer' ->> 'full_name'), nullif(trim(p -> 'customer' ->> 'phone'), ''),
            nullif(trim(p -> 'customer' ->> 'email'), ''), nullif(trim(p -> 'customer' ->> 'city'), ''),
            first_stage, person, null, me);
  end if;

  sale := gen_random_uuid();
  insert into public.sales (id, tenant_id, business_id, customer_id, lead_id, product_id, billing_company_id, quantity, plan,
                            base_amount, gst_applicable, gst_rate, gst_amount, total_amount, sale_date, valid_until,
                            sales_person_id, payment_mode_id, reference, payment_remark, notes, created_by)
  values (sale, t, b, cust, lead, prod.id, (p ->> 'billing_company_id')::uuid, qty, plan,
          base, gst_on, rate, gst, total, sdate,
          case when prod.lifetime or prod.validity_months is null then null
               else (sdate + make_interval(months => prod.validity_months))::date end,
          person, nullif(p ->> 'payment_mode_id', '')::uuid, nullif(trim(p ->> 'reference'), ''),
          nullif(trim(p ->> 'payment_remark'), ''), nullif(trim(p ->> 'notes'), ''), me);

  if paid_now > 0 then
    insert into public.payments (tenant_id, sale_id, customer_id, amount, paid_on, payment_mode_id, billing_company_id, reference, note, received_by)
    values (t, sale, cust, paid_now, sdate, nullif(p ->> 'payment_mode_id', '')::uuid, (p ->> 'billing_company_id')::uuid,
            nullif(trim(p ->> 'reference'), ''),
            case plan when 'booking' then 'Booking token' when 'emi' then 'Down payment' else null end, me);
  end if;

  rest := total - paid_now;
  if plan in ('full', 'booking') and rest > 0 then
    insert into public.sale_dues (tenant_id, sale_id, kind, seq, due_on, amount)
    values (t, sale, 'balance', 1, balance_on, rest);
  elsif plan = 'emi' then
    each_amt := floor(rest / n);
    for i in 1..n loop
      insert into public.sale_dues (tenant_id, sale_id, kind, seq, due_on, amount)
      values (t, sale, 'emi', i, (first_on + make_interval(months => i - 1))::date,
              case when i = n then rest - each_amt * (n - 1) else each_amt end);
    end loop;
  end if;

  return sale;
end;
$$;
revoke execute on function public.create_sale(jsonb) from public, anon;
grant execute on function public.create_sale(jsonb) to authenticated;
revoke all on public.products, public.billing_companies, public.payment_modes, public.customer_stages, public.customers, public.sales, public.sale_dues, public.payments from anon;

-- Demo data (Viral): products, billing companies and 3 customers with a full payment, a booking and an EMI sale,
-- inserted with execute_sql.
