-- Client feedback (Podcast Studio):
-- 1. Services: the products master is used as "services" (name + price, optional sub-business).
--    A booking has several services (price taken from the master, editable); bookings.amount = their sum.
-- 2. Payment plan: a booking's payments are planned parts (advance, pre-shoot, after-shoot…) with a due date,
--    comment, amount and status (pending / paid); overdue = pending past its due date. Only paid parts count as paid.
-- 4. Every booking gets its invoice number when it is created (1 booking = 1 invoice).

alter table public.products add column sub_business_id uuid references public.sub_businesses (id) on delete set null;

create table public.booking_items (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenants (id) on delete cascade,
  booking_id  uuid not null references public.bookings (id) on delete cascade,
  product_id  uuid references public.products (id) on delete set null,
  name        text not null,
  price       numeric(12,2) not null default 0 check (price >= 0),
  sort_order  int not null default 0,
  created_at  timestamptz not null default now()
);
create index booking_items_booking_idx on public.booking_items (booking_id);
alter table public.booking_items enable row level security;
create policy "booking_items: read" on public.booking_items for select to authenticated
  using (private.can_see_booking(booking_id));
create policy "booking_items: write" on public.booking_items for all to authenticated
  using ((private.has_permission(tenant_id, 'bookings', 'add') or private.has_permission(tenant_id, 'bookings', 'edit')) and private.can_see_booking(booking_id))
  with check ((private.has_permission(tenant_id, 'bookings', 'add') or private.has_permission(tenant_id, 'bookings', 'edit')) and private.can_see_booking(booking_id));
grant select, insert, update, delete on public.booking_items to authenticated;
revoke all on public.booking_items from anon;

alter table public.booking_payments add column label text;
alter table public.booking_payments add column due_on date;
alter table public.booking_payments add column status text not null default 'paid' check (status in ('pending', 'paid'));
alter table public.booking_payments alter column paid_on drop not null;
alter table public.booking_payments alter column paid_on drop default;
update public.booking_payments set due_on = paid_on, label = coalesce(nullif(reference, ''), 'Payment') where due_on is null;

create policy "booking_payments: update" on public.booking_payments for update to authenticated
  using ((private.has_permission(tenant_id, 'bookings', 'edit') or private.has_permission(tenant_id, 'payments', 'add')) and private.can_see_booking(booking_id))
  with check ((private.has_permission(tenant_id, 'bookings', 'edit') or private.has_permission(tenant_id, 'payments', 'add')) and private.can_see_booking(booking_id));
grant update on public.booking_payments to authenticated;

create or replace function private.sync_booking_paid()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare b uuid := coalesce(new.booking_id, old.booking_id);
begin
  update public.bookings
  set paid_amount = coalesce((select sum(amount) from public.booking_payments where booking_id = b and status = 'paid'), 0)
  where id = b;
  return null;
end;
$$;

-- invoice number on creation (same numbering as booking_invoice: billing company prefix, else per business)
create or replace function private.assign_booking_invoice(p_booking uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  b     public.bookings;
  c     public.billing_companies;
  v_fy  text;
  n     int;
begin
  select * into b from public.bookings where id = p_booking;
  if b.id is null or b.invoice_no is not null or b.status = 'cancelled' then return; end if;
  select * into c from public.billing_companies where id = b.billing_company_id;
  v_fy := case when extract(month from coalesce(b.created_at, now())) >= 4
               then to_char(coalesce(b.created_at, now()), 'YY') || '-' || to_char(coalesce(b.created_at, now()) + interval '1 year', 'YY')
               else to_char(coalesce(b.created_at, now()) - interval '1 year', 'YY') || '-' || to_char(coalesce(b.created_at, now()), 'YY') end;
  if c.id is not null then
    insert into public.invoice_counters as ic (billing_company_id, fy, last_no) values (c.id, v_fy, 1)
    on conflict (billing_company_id, fy) do update set last_no = ic.last_no + 1 returning ic.last_no into n;
    update public.bookings set invoice_no = coalesce(nullif(c.invoice_prefix, ''), 'INV') || '/' || v_fy || '/' || lpad(n::text, 4, '0'),
                               invoice_date = coalesce(b.created_at::date, current_date) where id = b.id;
  else
    insert into public.business_invoice_counters as bc (business_id, fy, last_no) values (b.business_id, v_fy, 1)
    on conflict (business_id, fy) do update set last_no = bc.last_no + 1 returning bc.last_no into n;
    update public.bookings set invoice_no = 'INV/' || v_fy || '/' || lpad(n::text, 4, '0'),
                               invoice_date = coalesce(b.created_at::date, current_date) where id = b.id;
  end if;
end;
$$;
revoke all on function private.assign_booking_invoice(uuid) from public, anon, authenticated;

create or replace function private.booking_invoice_on_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.assign_booking_invoice(new.id);
  return null;
end;
$$;
create trigger bookings_invoice_on_insert after insert on public.bookings
  for each row execute function private.booking_invoice_on_insert();

-- existing bookings without a number
do $$
declare r record;
begin
  for r in select id from public.bookings where invoice_no is null and status <> 'cancelled' order by created_at loop
    perform private.assign_booking_invoice(r.id);
  end loop;
end $$;
