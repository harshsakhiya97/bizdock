-- Refund on a course purchase (rough first version: one refund per purchase)
alter table public.purchases
  add column if not exists refund_amount numeric not null default 0 check (refund_amount >= 0),
  add column if not exists refund_reason text,
  add column if not exists refunded_on date;

-- Expenses: what the business spends besides what it sells (ad spend, salary, rent…)
create table if not exists public.expenses (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  business_id uuid references public.businesses(id) on delete set null,
  spent_on date not null default current_date,
  category text not null default 'Other',
  amount numeric not null check (amount >= 0),
  note text,
  created_by uuid references public.tenant_members(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists expenses_tenant_date on public.expenses (tenant_id, spent_on);
alter table public.expenses enable row level security;
create policy "expenses: read" on public.expenses for select
  using ((private.is_member(tenant_id) or private.is_platform_owner()) and (business_id is null or private.can_access_business(business_id)));
create policy "expenses: write" on public.expenses for all
  using (private.has_permission(tenant_id, 'expenses', 'edit'))
  with check (private.has_permission(tenant_id, 'expenses', 'edit'));
create trigger expenses_set_updated_at before update on public.expenses for each row execute function public.set_updated_at();
grant select, insert, update, delete on public.expenses to authenticated;
