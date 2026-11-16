-- Default / Brand Deals: orders are added without GST or payments and without an invoice.
-- An invoice is generated later from the Orders list for one or more orders of the same client:
-- GST and the payment parts live on the invoice. Orders can be added to / removed from it.

create table if not exists public.invoices (
  id                 uuid primary key default gen_random_uuid(),
  tenant_id          uuid not null references public.tenants(id) on delete cascade,
  business_id        uuid not null references public.businesses(id) on delete cascade,
  sub_business_id    uuid references public.sub_businesses(id) on delete set null,
  customer_id        uuid references public.customers(id) on delete set null,
  lead_id            uuid references public.leads(id) on delete set null,
  client_name        text not null,
  phone              text,
  billing_company_id uuid references public.billing_companies(id) on delete set null,
  invoice_no         text not null,
  invoice_date       date not null default current_date,
  gst_applicable     boolean not null default false,
  gst_rate           numeric not null default 18,
  amount             numeric not null default 0,
  gst_amount         numeric not null default 0,
  total_amount       numeric not null default 0,
  paid_amount        numeric not null default 0,
  notes              text,
  created_by         uuid references public.tenant_members(id) on delete set null,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);
create index if not exists invoices_tenant_idx on public.invoices (tenant_id, business_id);

create table if not exists public.invoice_payments (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenants(id) on delete cascade,
  invoice_id      uuid not null references public.invoices(id) on delete cascade,
  label           text,
  amount          numeric not null check (amount > 0),
  due_on          date,
  status          text not null default 'pending' check (status in ('pending', 'paid')),
  paid_on         date,
  payment_mode_id uuid references public.payment_modes(id) on delete set null,
  reference       text,
  note            text,
  received_by     uuid references public.tenant_members(id) on delete set null,
  created_at      timestamptz not null default now()
);
create index if not exists invoice_payments_invoice_idx on public.invoice_payments (invoice_id);

alter table public.bookings add column if not exists invoice_id uuid references public.invoices(id) on delete set null;
create index if not exists bookings_invoice_idx on public.bookings (invoice_id);

drop trigger if exists invoices_set_updated_at on public.invoices;
create trigger invoices_set_updated_at before update on public.invoices for each row execute function public.set_updated_at();

-- ---------- access ----------
create or replace function private.can_see_invoice(inv uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.invoices i where i.id = inv
                 and private.can_see_owned(i.tenant_id, i.business_id, i.created_by, 'sales')
                 and private.can_access_sub(i.business_id, i.sub_business_id))
$$;

alter table public.invoices enable row level security;
alter table public.invoice_payments enable row level security;
drop policy if exists "invoices: read" on public.invoices;
create policy "invoices: read" on public.invoices for select to authenticated
  using (private.can_see_owned(tenant_id, business_id, created_by, 'sales') and private.can_access_sub(business_id, sub_business_id));
drop policy if exists "invoices: update" on public.invoices;
create policy "invoices: update" on public.invoices for update to authenticated
  using (private.has_permission(tenant_id, 'bookings', 'edit') and private.can_see_owned(tenant_id, business_id, created_by, 'sales') and private.can_access_sub(business_id, sub_business_id))
  with check (private.can_access_business(business_id) and private.can_access_sub(business_id, sub_business_id));
drop policy if exists "invoice_payments: read" on public.invoice_payments;
create policy "invoice_payments: read" on public.invoice_payments for select to authenticated using (private.can_see_invoice(invoice_id));
drop policy if exists "invoice_payments: insert" on public.invoice_payments;
create policy "invoice_payments: insert" on public.invoice_payments for insert to authenticated
  with check ((private.has_permission(tenant_id, 'bookings', 'edit') or private.has_permission(tenant_id, 'payments', 'add')) and private.can_see_invoice(invoice_id));
drop policy if exists "invoice_payments: update" on public.invoice_payments;
create policy "invoice_payments: update" on public.invoice_payments for update to authenticated
  using ((private.has_permission(tenant_id, 'bookings', 'edit') or private.has_permission(tenant_id, 'payments', 'add')) and private.can_see_invoice(invoice_id))
  with check ((private.has_permission(tenant_id, 'bookings', 'edit') or private.has_permission(tenant_id, 'payments', 'add')) and private.can_see_invoice(invoice_id));
drop policy if exists "invoice_payments: delete" on public.invoice_payments;
create policy "invoice_payments: delete" on public.invoice_payments for delete to authenticated
  using (private.has_permission(tenant_id, 'bookings', 'edit') and private.can_see_invoice(invoice_id));
grant select, update on public.invoices to authenticated;
grant select, insert, update, delete on public.invoice_payments to authenticated;

-- ---------- invoice number (same series as bookings: per billing company, else per business, per financial year) ----------
create or replace function private.next_invoice_no(p_business uuid, p_company uuid) returns text
language plpgsql security definer set search_path = '' as $$
declare
  c    public.billing_companies;
  v_fy text := case when extract(month from current_date) >= 4
                    then to_char(current_date, 'YY') || '-' || to_char(current_date + interval '1 year', 'YY')
                    else to_char(current_date - interval '1 year', 'YY') || '-' || to_char(current_date, 'YY') end;
  n    int;
begin
  select * into c from public.billing_companies where id = p_company;
  if c.id is not null then
    insert into public.invoice_counters as ic (billing_company_id, fy, last_no) values (c.id, v_fy, 1)
    on conflict (billing_company_id, fy) do update set last_no = ic.last_no + 1 returning ic.last_no into n;
    return coalesce(nullif(c.invoice_prefix, ''), 'INV') || '/' || v_fy || '/' || lpad(n::text, 4, '0');
  end if;
  insert into public.business_invoice_counters as bc (business_id, fy, last_no) values (p_business, v_fy, 1)
  on conflict (business_id, fy) do update set last_no = bc.last_no + 1 returning bc.last_no into n;
  return 'INV/' || v_fy || '/' || lpad(n::text, 4, '0');
end $$;

-- ---------- paid → spread over the invoice's orders (oldest first), so each order's paid / balance stays right ----------
create or replace function private.invoice_allocate(p_inv uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  left_ numeric;
  b record;
  pay numeric;
begin
  select paid_amount into left_ from public.invoices where id = p_inv;
  if left_ is null then return; end if;
  for b in select id, total_amount, paid_amount, status from public.bookings where invoice_id = p_inv order by created_at, order_no loop
    pay := case when b.status = 'cancelled' then 0 else least(b.total_amount, greatest(left_, 0)) end;
    left_ := left_ - pay;
    if b.paid_amount is distinct from pay then update public.bookings set paid_amount = pay where id = b.id; end if;
  end loop;
end $$;

-- ---------- totals from the orders; the last unpaid part takes any change; paid can't exceed the total ----------
create or replace function private.invoice_recalc(p_inv uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  i   public.invoices;
  a   numeric; g numeric; t numeric;
  d   numeric;
  p   record;
begin
  select * into i from public.invoices where id = p_inv;
  if i.id is null then return; end if;
  select coalesce(sum(amount), 0), coalesce(sum(gst_amount), 0), coalesce(sum(total_amount), 0) into a, g, t
    from public.bookings where invoice_id = p_inv and status <> 'cancelled';
  if i.paid_amount > t + 0.01 then
    raise exception 'Invoice % has % paid, more than its new total %. Change the payments first.',
      i.invoice_no, to_char(i.paid_amount, 'FM₹99,99,99,990.00'), to_char(t, 'FM₹99,99,99,990.00');
  end if;
  d := t - i.total_amount;
  update public.invoices set amount = a, gst_amount = g, total_amount = t where id = p_inv;
  if abs(d) > 0.005 and coalesce(current_setting('bizdock.no_adjust', true), '') <> 'on'
     and exists (select 1 from public.invoice_payments where invoice_id = p_inv) then
    if d > 0 then
      select id into p from public.invoice_payments where invoice_id = p_inv and status = 'pending'
       order by coalesce(due_on, '9999-12-31'::date) desc, created_at desc limit 1;
      if p.id is not null then
        update public.invoice_payments set amount = amount + d where id = p.id;
      else
        insert into public.invoice_payments (tenant_id, invoice_id, label, amount, due_on, status)
        values (i.tenant_id, p_inv, 'Balance', d, current_date, 'pending');
      end if;
    else
      d := -d;
      for p in select id, amount from public.invoice_payments where invoice_id = p_inv and status = 'pending'
                order by coalesce(due_on, '9999-12-31'::date) desc, created_at desc loop
        exit when d <= 0.005;
        if p.amount > d + 0.005 then
          update public.invoice_payments set amount = amount - d where id = p.id;
          d := 0;
        else
          delete from public.invoice_payments where id = p.id;
          d := d - p.amount;
        end if;
      end loop;
    end if;
  end if;
  perform private.invoice_allocate(p_inv);
end $$;

-- invoice parts → paid
create or replace function private.invoice_payments_sync() returns trigger
language plpgsql security definer set search_path = '' as $$
declare inv uuid := coalesce(new.invoice_id, old.invoice_id);
begin
  update public.invoices
     set paid_amount = coalesce((select sum(amount) from public.invoice_payments where invoice_id = inv and status = 'paid'), 0)
   where id = inv;
  perform private.invoice_allocate(inv);
  return null;
end $$;
drop trigger if exists invoice_payments_sync on public.invoice_payments;
create trigger invoice_payments_sync after insert or update or delete on public.invoice_payments
  for each row execute function private.invoice_payments_sync();

-- invoice GST → its orders (each order's GST is worked out on the order, the invoice adds them up)
create or replace function private.invoice_gst_to_orders() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  update public.bookings set gst_applicable = new.gst_applicable, gst_rate = new.gst_rate where invoice_id = new.id;
  return null;
end $$;
drop trigger if exists invoices_gst on public.invoices;
create trigger invoices_gst after update of gst_applicable, gst_rate on public.invoices
  for each row execute function private.invoice_gst_to_orders();

-- an order: GST and invoice number from its invoice; locked once the invoice is fully paid
create or replace function private.booking_invoice_link() returns trigger
language plpgsql security definer set search_path = '' as $$
declare i public.invoices;
begin
  if new.invoice_id is not null then
    select * into i from public.invoices where id = new.invoice_id;
    new.gst_applicable := i.gst_applicable;
    new.gst_rate := i.gst_rate;
    -- the number lives on the invoice (bookings.invoice_no is unique; several orders share one invoice)
    new.invoice_no := null;
    new.invoice_date := null;
    new.billing_company_id := i.billing_company_id;
  elsif private.is_default_biz(new.business_id, new.sub_business_id) then
    new.gst_applicable := false;
    new.invoice_no := null;
    new.invoice_date := null;
  end if;
  if tg_op = 'UPDATE' and old.invoice_id is not null and old.invoice_id is not distinct from new.invoice_id
     and new.amount is distinct from old.amount then
    select * into i from public.invoices where id = old.invoice_id;
    if i.total_amount > 0 and i.paid_amount >= i.total_amount - 0.01 then
      raise exception 'Invoice % is fully paid, so % can’t be changed.', i.invoice_no, coalesce(old.order_no, 'this order');
    end if;
  end if;
  return new;
end $$;
drop trigger if exists bookings_a_invoice_link on public.bookings;
create trigger bookings_a_invoice_link before insert or update on public.bookings
  for each row execute function private.booking_invoice_link();

create or replace function private.booking_invoice_recalc() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op <> 'INSERT' and old.invoice_id is not null then perform private.invoice_recalc(old.invoice_id); end if;
  if tg_op <> 'DELETE' and new.invoice_id is not null and (tg_op = 'INSERT' or new.invoice_id is distinct from old.invoice_id or old.invoice_id is null) then
    perform private.invoice_recalc(new.invoice_id);
  end if;
  return null;
end $$;
drop trigger if exists bookings_invoice_recalc on public.bookings;
create trigger bookings_invoice_recalc after insert or update of amount, gst_applicable, gst_rate, status, invoice_id or delete on public.bookings
  for each row execute function private.booking_invoice_recalc();

-- orders no longer get an invoice by themselves
create or replace function private.assign_booking_invoice(p_booking uuid)
 returns void language plpgsql security definer set search_path to '' as $function$
declare
  b     public.bookings;
  c     public.billing_companies;
  v_fy  text;
  n     int;
begin
  select * into b from public.bookings where id = p_booking;
  if b.id is null or b.invoice_no is not null or b.status = 'cancelled' then return; end if;
  if private.is_default_biz(b.business_id, b.sub_business_id) then return; end if;
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
$function$;

create or replace function public.booking_invoice(p_booking uuid, p_company uuid)
 returns text language plpgsql security definer set search_path to '' as $function$
declare
  b     public.bookings;
  v_no  text;
begin
  select * into b from public.bookings where id = p_booking;
  if b.id is null or not private.can_see_booking(b.id) then raise exception 'Booking not found.'; end if;
  if not private.has_permission(b.tenant_id, 'bookings', 'edit') then raise exception 'You don’t have permission to create invoices.'; end if;
  if b.invoice_no is not null then return b.invoice_no; end if;
  if b.status = 'cancelled' then raise exception 'A cancelled booking has no invoice.'; end if;
  if private.is_default_biz(b.business_id, b.sub_business_id) then raise exception 'Generate this invoice from the Orders list.'; end if;
  v_no := private.next_invoice_no(b.business_id, (select id from public.billing_companies where id = coalesce(p_company, b.billing_company_id) and tenant_id = b.tenant_id));
  update public.bookings set invoice_no = v_no, invoice_date = current_date,
         billing_company_id = (select id from public.billing_companies where id = coalesce(p_company, b.billing_company_id) and tenant_id = b.tenant_id)
   where id = b.id;
  return v_no;
end;
$function$;

-- ---------- RPCs ----------
-- the client an order belongs to (same client = same customer, else same lead, else same name + phone)
create or replace function private.order_client(b public.bookings) returns text
language sql immutable set search_path = '' as $$
  select coalesce('c' || b.customer_id::text, 'l' || b.lead_id::text, 'n' || lower(trim(b.client_name)) || '|' || coalesce(b.phone, ''))
$$;

create or replace function private.check_orders(p_orders uuid[], p_invoice public.invoices) returns public.bookings
language plpgsql security definer set search_path = '' as $$
declare
  b public.bookings;
  first_ public.bookings;
  key_ text;
begin
  if coalesce(array_length(p_orders, 1), 0) = 0 then raise exception 'Pick at least one order.'; end if;
  for b in select * from public.bookings where id = any(p_orders) order by created_at loop
    if not private.can_see_booking(b.id) or not private.is_default_biz(b.business_id, b.sub_business_id) then raise exception 'Order not found.'; end if;
    if b.status = 'cancelled' then raise exception '% is cancelled, so it can’t be invoiced.', b.order_no; end if;
    if b.invoice_id is not null then raise exception '% is already on invoice %.', b.order_no, (select invoice_no from public.invoices where id = b.invoice_id); end if;
    if first_.id is null then first_ := b; key_ := private.order_client(b); end if;
    if private.order_client(b) <> key_ or b.business_id <> first_.business_id then
      raise exception 'Pick orders of one client only: % is for %, % is for %.', first_.order_no, first_.client_name, b.order_no, b.client_name;
    end if;
    if p_invoice.id is not null and (b.business_id <> p_invoice.business_id
       or coalesce('c' || p_invoice.customer_id::text, 'l' || p_invoice.lead_id::text, 'n' || lower(trim(p_invoice.client_name)) || '|' || coalesce(p_invoice.phone, '')) <> key_) then
      raise exception '% is for %, not this invoice’s client.', b.order_no, b.client_name;
    end if;
  end loop;
  if first_.id is null or (select count(*) from public.bookings where id = any(p_orders)) <> (select count(distinct x) from unnest(p_orders) x) then
    raise exception 'Order not found.';
  end if;
  return first_;
end $$;

-- generate one invoice for orders of one client, with GST and the payment parts
create or replace function public.invoice_create(p_orders uuid[], p_company uuid, p_gst boolean, p_rate numeric, p_parts jsonb)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  f    public.bookings;
  none public.invoices;
  inv  uuid := gen_random_uuid();
  comp uuid;
  me   uuid;
  tot  numeric;
  planned numeric;
  p    jsonb;
begin
  f := private.check_orders(p_orders, none);
  if not (private.has_permission(f.tenant_id, 'bookings', 'add') or private.has_permission(f.tenant_id, 'bookings', 'edit')) then
    raise exception 'You don’t have permission to create invoices.';
  end if;
  me := private.my_member_id(f.tenant_id);
  select id into comp from public.billing_companies where id = p_company and tenant_id = f.tenant_id;
  insert into public.invoices (id, tenant_id, business_id, sub_business_id, customer_id, lead_id, client_name, phone,
                               billing_company_id, invoice_no, gst_applicable, gst_rate, created_by)
  values (inv, f.tenant_id, f.business_id, f.sub_business_id, f.customer_id, f.lead_id, f.client_name, f.phone,
          comp, private.next_invoice_no(f.business_id, comp), coalesce(p_gst, false), coalesce(p_rate, 18), me);
  perform set_config('bizdock.no_adjust', 'on', true);
  update public.bookings set invoice_id = inv where id = any(p_orders);
  perform set_config('bizdock.no_adjust', '', true);
  select total_amount into tot from public.invoices where id = inv;
  select coalesce(sum((x->>'amount')::numeric), 0) into planned from jsonb_array_elements(coalesce(p_parts, '[]'::jsonb)) x;
  if planned > tot + 0.01 then
    raise exception 'The payment parts add up to %, more than the invoice total %.', to_char(planned, 'FM₹99,99,99,990.00'), to_char(tot, 'FM₹99,99,99,990.00');
  end if;
  for p in select * from jsonb_array_elements(coalesce(p_parts, '[]'::jsonb)) loop
    if coalesce((p->>'amount')::numeric, 0) <= 0 then continue; end if;
    insert into public.invoice_payments (tenant_id, invoice_id, label, amount, due_on, status, paid_on, payment_mode_id, note, received_by)
    values (f.tenant_id, inv, coalesce(nullif(trim(p->>'label'), ''), 'Payment'), (p->>'amount')::numeric, nullif(p->>'due_on', '')::date,
            case when p->>'status' = 'paid' then 'paid' else 'pending' end,
            case when p->>'status' = 'paid' then coalesce(nullif(p->>'paid_on', '')::date, current_date) end,
            (select id from public.payment_modes where id = nullif(p->>'mode', '')::uuid and tenant_id = f.tenant_id),
            nullif(trim(p->>'note'), ''), case when p->>'status' = 'paid' then me end);
  end loop;
  return inv;
end $$;

create or replace function public.invoice_add_orders(p_invoice uuid, p_orders uuid[])
returns void language plpgsql security definer set search_path = '' as $$
declare i public.invoices;
begin
  select * into i from public.invoices where id = p_invoice;
  if i.id is null or not private.can_see_invoice(i.id) then raise exception 'Invoice not found.'; end if;
  if not private.has_permission(i.tenant_id, 'bookings', 'edit') then raise exception 'You don’t have permission to change invoices.'; end if;
  perform private.check_orders(p_orders, i);
  update public.bookings set invoice_id = p_invoice where id = any(p_orders);
end $$;

create or replace function public.invoice_remove_order(p_order uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare b public.bookings;
begin
  select * into b from public.bookings where id = p_order;
  if b.id is null or b.invoice_id is null or not private.can_see_invoice(b.invoice_id) then raise exception 'Order not found on an invoice.'; end if;
  if not private.has_permission(b.tenant_id, 'bookings', 'edit') then raise exception 'You don’t have permission to change invoices.'; end if;
  if not exists (select 1 from public.bookings where invoice_id = b.invoice_id and id <> b.id) then
    raise exception 'An invoice needs at least one order: % is the only one on %.', b.order_no, (select invoice_no from public.invoices where id = b.invoice_id);
  end if;
  update public.bookings set invoice_id = null, paid_amount = 0 where id = b.id;
end $$;

revoke all on function public.invoice_create(uuid[], uuid, boolean, numeric, jsonb) from public, anon;
revoke all on function public.invoice_add_orders(uuid, uuid[]) from public, anon;
revoke all on function public.invoice_remove_order(uuid) from public, anon;
grant execute on function public.invoice_create(uuid[], uuid, boolean, numeric, jsonb) to authenticated;
grant execute on function public.invoice_add_orders(uuid, uuid[]) to authenticated;
grant execute on function public.invoice_remove_order(uuid) to authenticated;

-- ---------- orders already invoiced (test data): each becomes its own invoice, its parts move to the invoice ----------
do $$
declare b public.bookings; inv uuid;
begin
  for b in select * from public.bookings where invoice_id is null and private.is_default_biz(business_id, sub_business_id) order by created_at loop
    if b.invoice_no is not null and b.status <> 'cancelled' then
      inv := gen_random_uuid();
      insert into public.invoices (id, tenant_id, business_id, sub_business_id, customer_id, lead_id, client_name, phone,
                                   billing_company_id, invoice_no, invoice_date, gst_applicable, gst_rate, created_by, created_at)
      values (inv, b.tenant_id, b.business_id, b.sub_business_id, b.customer_id, b.lead_id, b.client_name, b.phone,
              b.billing_company_id, b.invoice_no, coalesce(b.invoice_date, b.booking_date), b.gst_applicable, b.gst_rate, b.created_by, b.created_at);
      insert into public.invoice_payments (tenant_id, invoice_id, label, amount, due_on, status, paid_on, payment_mode_id, reference, note, received_by, created_at)
      select tenant_id, inv, label, amount, due_on, status, paid_on, payment_mode_id, reference, note, received_by, created_at
        from public.booking_payments where booking_id = b.id;
      perform set_config('bizdock.no_adjust', 'on', true);
      update public.bookings set invoice_id = inv where id = b.id;
      perform set_config('bizdock.no_adjust', '', true);
      delete from public.booking_payments where booking_id = b.id;
      perform private.invoice_allocate(inv);
    else
      -- not invoiced: no GST, no invoice number, no parts
      delete from public.booking_payments where booking_id = b.id;
      update public.bookings set gst_applicable = false, invoice_no = null, invoice_date = null where id = b.id;
    end if;
  end loop;
end $$;

-- orders on an invoice carry no number of their own (it is on the invoice)
update public.bookings set invoice_no = null, invoice_date = null where invoice_id is not null;
