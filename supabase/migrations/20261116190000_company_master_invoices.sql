-- Company Master (billing companies grown): address, state + code, CIN, PAN, email, bank details, number format + next number.
-- Businesses / sub-businesses pick a company for GST invoices and (optionally) another for non-GST invoices.
-- Services: name on the GST bill + HSN / SAC. Clients (leads): billing details.
-- Invoices: With GST / Without GST, the seller (company) and buyer (client) details kept on the invoice.
-- Every booking (not only orders) is invoiced from its list: the booking has no GST / payments of its own.

alter table public.billing_companies
  add column if not exists email text,
  add column if not exists state_code text,
  add column if not exists cin text,
  add column if not exists pan text,
  add column if not exists bank_holder text,
  add column if not exists bank_name text,
  add column if not exists bank_account text,
  add column if not exists bank_branch text,
  add column if not exists bank_ifsc text,
  add column if not exists number_format text not null default '{N}',
  add column if not exists next_no integer not null default 1 check (next_no >= 1);

-- existing companies keep their numbering (PREFIX/26-27/0004 …)
update public.billing_companies c
   set number_format = coalesce(nullif(c.invoice_prefix, ''), 'INV') || '/{FY}/{NNNN}',
       next_no = coalesce((select max(last_no) from public.invoice_counters i where i.billing_company_id = c.id
                            and i.fy = case when extract(month from current_date) >= 4
                                            then to_char(current_date, 'YY') || '-' || to_char(current_date + interval '1 year', 'YY')
                                            else to_char(current_date - interval '1 year', 'YY') || '-' || to_char(current_date, 'YY') end), 0) + 1
 where c.number_format = '{N}';

alter table public.businesses
  add column if not exists company_id uuid references public.billing_companies(id) on delete set null,
  add column if not exists nongst_company_id uuid references public.billing_companies(id) on delete set null;
alter table public.sub_businesses
  add column if not exists company_id uuid references public.billing_companies(id) on delete set null,
  add column if not exists nongst_company_id uuid references public.billing_companies(id) on delete set null;

alter table public.products
  add column if not exists gst_name text,
  add column if not exists hsn_code text;

alter table public.leads
  add column if not exists bill_company text,
  add column if not exists bill_address text,
  add column if not exists bill_state text,
  add column if not exists bill_state_code text,
  add column if not exists bill_gstin text;

alter table public.invoices
  add column if not exists kind text not null default 'gst' check (kind in ('gst', 'nongst')),
  add column if not exists seller jsonb not null default '{}'::jsonb,
  add column if not exists buyer jsonb not null default '{}'::jsonb;

-- ---------- numbers ----------
create or replace function private.fy_of(d date) returns text
language sql immutable set search_path = '' as $$
  select case when extract(month from d) >= 4 then to_char(d, 'YY') || '-' || to_char(d + interval '1 year', 'YY')
              else to_char(d - interval '1 year', 'YY') || '-' || to_char(d, 'YY') end
$$;

-- the company's next invoice number from its format: {N} 8, {NNNN} 0008, {FY} 26-27, {PREFIX} its prefix
create or replace function private.company_next_no(p_company uuid) returns text
language plpgsql security definer set search_path = '' as $$
declare n int; f text; px text;
begin
  update public.billing_companies set next_no = next_no + 1 where id = p_company
  returning next_no - 1, number_format, coalesce(invoice_prefix, '') into n, f, px;
  if n is null then raise exception 'Company not found.'; end if;
  f := coalesce(nullif(trim(f), ''), '{N}');
  if position('{N' in f) = 0 then f := f || '{N}'; end if;
  return replace(replace(replace(replace(f, '{NNNN}', lpad(n::text, 4, '0')), '{N}', n::text), '{FY}', private.fy_of(current_date)), '{PREFIX}', px);
end $$;

create or replace function private.next_invoice_no(p_business uuid, p_company uuid) returns text
language plpgsql security definer set search_path = '' as $$
declare n int; v_fy text := private.fy_of(current_date);
begin
  if p_company is not null and exists (select 1 from public.billing_companies where id = p_company) then
    return private.company_next_no(p_company);
  end if;
  insert into public.business_invoice_counters as bc (business_id, fy, last_no) values (p_business, v_fy, 1)
  on conflict (business_id, fy) do update set last_no = bc.last_no + 1 returning bc.last_no into n;
  return 'INV/' || v_fy || '/' || lpad(n::text, 4, '0');
end $$;

-- ---------- seller / buyer details kept on the invoice ----------
create or replace function private.seller_of(p_company uuid, p_business uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(
    (select jsonb_build_object('company_id', c.id, 'name', coalesce(nullif(c.legal_name, ''), c.name), 'address', c.address, 'email', c.email,
                               'gstin', c.gst_number, 'state', c.state, 'state_code', c.state_code, 'cin', c.cin, 'pan', c.pan,
                               'bank_holder', coalesce(nullif(c.bank_holder, ''), nullif(c.legal_name, ''), c.name), 'bank_name', c.bank_name,
                               'bank_account', c.bank_account, 'bank_branch', c.bank_branch, 'bank_ifsc', c.bank_ifsc)
       from public.billing_companies c where c.id = p_company),
    (select jsonb_build_object('name', coalesce(nullif(b.legal_name, ''), b.name), 'address', concat_ws(', ', nullif(b.address, ''), nullif(b.city, '')),
                               'email', b.email, 'gstin', b.gst_number, 'state', b.state)
       from public.businesses b where b.id = p_business),
    '{}'::jsonb)
$$;

-- the client's billing details: the invoice's copy, and saved on the lead for next time
create or replace function private.buyer_json(p_name text, p_phone text, p jsonb) returns jsonb
language sql immutable set search_path = '' as $$
  select jsonb_build_object('name', p_name, 'phone', p_phone,
    'company', nullif(trim(coalesce(p->>'company', '')), ''), 'address', nullif(trim(coalesce(p->>'address', '')), ''),
    'state', nullif(trim(coalesce(p->>'state', '')), ''), 'state_code', nullif(trim(coalesce(p->>'state_code', '')), ''),
    'gstin', nullif(upper(trim(coalesce(p->>'gstin', ''))), ''))
$$;

create or replace function private.save_lead_billing(p_lead uuid, b jsonb) returns void
language sql security definer set search_path = '' as $$
  update public.leads set bill_company = b->>'company', bill_address = b->>'address', bill_state = b->>'state',
                          bill_state_code = b->>'state_code', bill_gstin = b->>'gstin'
   where id = p_lead
$$;

-- ---------- bookings: every booking is invoiced from its list ----------
create or replace function private.booking_invoice_link() returns trigger
language plpgsql security definer set search_path = '' as $$
declare i public.invoices;
begin
  if new.invoice_id is not null then
    select * into i from public.invoices where id = new.invoice_id;
    new.gst_applicable := i.gst_applicable;
    new.gst_rate := i.gst_rate;
    new.billing_company_id := i.billing_company_id;
  else
    new.gst_applicable := false;
  end if;
  -- the number lives on the invoice (several bookings share one invoice)
  new.invoice_no := null;
  new.invoice_date := null;
  if tg_op = 'UPDATE' and old.invoice_id is not null and old.invoice_id is not distinct from new.invoice_id
     and new.amount is distinct from old.amount then
    select * into i from public.invoices where id = old.invoice_id;
    if i.total_amount > 0 and i.paid_amount >= i.total_amount - 0.01 then
      raise exception 'Invoice % is fully paid, so % can’t be changed.', i.invoice_no, coalesce(old.order_no, 'this booking');
    end if;
  end if;
  return new;
end $$;

drop trigger if exists bookings_invoice_on_insert on public.bookings;

create or replace function public.booking_invoice(p_booking uuid, p_company uuid)
 returns text language plpgsql security definer set search_path to '' as $function$
begin
  raise exception 'Generate the invoice from the Bookings list: tick the booking → Generate invoice.';
end;
$function$;

create or replace function private.check_orders(p_orders uuid[], p_invoice public.invoices) returns public.bookings
language plpgsql security definer set search_path = '' as $$
declare
  b public.bookings;
  first_ public.bookings;
  key_ text;
  nm text;
begin
  if coalesce(array_length(p_orders, 1), 0) = 0 then raise exception 'Pick at least one booking.'; end if;
  for b in select * from public.bookings where id = any(p_orders) order by created_at loop
    nm := coalesce(b.order_no, 'The booking on ' || to_char(b.booking_date, 'DD Mon'));
    if not private.can_see_booking(b.id) then raise exception 'Booking not found.'; end if;
    if b.status = 'cancelled' then raise exception '% is cancelled, so it can’t be invoiced.', nm; end if;
    if b.invoice_id is not null then raise exception '% is already on invoice %.', nm, (select invoice_no from public.invoices where id = b.invoice_id); end if;
    if first_.id is null then first_ := b; key_ := private.order_client(b); end if;
    if private.order_client(b) <> key_ or b.business_id <> first_.business_id then
      raise exception 'Pick bookings of one client only: % is for %, % is for %.', coalesce(first_.order_no, to_char(first_.booking_date, 'DD Mon')), first_.client_name, nm, b.client_name;
    end if;
    if p_invoice.id is not null and (b.business_id <> p_invoice.business_id
       or coalesce('c' || p_invoice.customer_id::text, 'l' || p_invoice.lead_id::text, 'n' || lower(trim(p_invoice.client_name)) || '|' || coalesce(p_invoice.phone, '')) <> key_) then
      raise exception '% is for %, not this invoice’s client.', nm, b.client_name;
    end if;
  end loop;
  if first_.id is null or (select count(*) from public.bookings where id = any(p_orders)) <> (select count(distinct x) from unnest(p_orders) x) then
    raise exception 'Booking not found.';
  end if;
  return first_;
end $$;

drop function if exists public.invoice_create(uuid[], uuid, boolean, numeric, jsonb);
-- one invoice for bookings / orders of one client: With GST or Without GST, from a company, to the client's billing details
create or replace function public.invoice_create(p_orders uuid[], p_kind text, p_company uuid, p_rate numeric, p_buyer jsonb, p_parts jsonb)
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
  buyer jsonb;
begin
  if p_kind not in ('gst', 'nongst') then raise exception 'Pick With GST or Without GST.'; end if;
  f := private.check_orders(p_orders, none);
  if not (private.has_permission(f.tenant_id, 'bookings', 'add') or private.has_permission(f.tenant_id, 'bookings', 'edit')) then
    raise exception 'You don’t have permission to create invoices.';
  end if;
  me := private.my_member_id(f.tenant_id);
  select id into comp from public.billing_companies where id = p_company and tenant_id = f.tenant_id;
  buyer := private.buyer_json(f.client_name, f.phone, coalesce(p_buyer, '{}'::jsonb));
  insert into public.invoices (id, tenant_id, business_id, sub_business_id, customer_id, lead_id, client_name, phone,
                               billing_company_id, invoice_no, kind, gst_applicable, gst_rate, seller, buyer, created_by)
  values (inv, f.tenant_id, f.business_id, f.sub_business_id, f.customer_id, f.lead_id, f.client_name, f.phone,
          comp, private.next_invoice_no(f.business_id, comp), p_kind, p_kind = 'gst', coalesce(p_rate, 18),
          private.seller_of(comp, f.business_id), buyer, me);
  if f.lead_id is not null then perform private.save_lead_billing(f.lead_id, buyer); end if;
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

-- the invoice's Bill to details (also saved on the client)
create or replace function public.invoice_set_buyer(p_invoice uuid, p_buyer jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare i public.invoices; b jsonb;
begin
  select * into i from public.invoices where id = p_invoice;
  if i.id is null or not private.can_see_invoice(i.id) then raise exception 'Invoice not found.'; end if;
  if not private.has_permission(i.tenant_id, 'bookings', 'edit') then raise exception 'You don’t have permission to change invoices.'; end if;
  b := private.buyer_json(i.client_name, i.phone, coalesce(p_buyer, '{}'::jsonb));
  update public.invoices set buyer = b where id = i.id;
  if i.lead_id is not null then perform private.save_lead_billing(i.lead_id, b); end if;
end $$;

create or replace function public.invoice_remove_order(p_order uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare b public.bookings;
begin
  select * into b from public.bookings where id = p_order;
  if b.id is null or b.invoice_id is null or not private.can_see_invoice(b.invoice_id) then raise exception 'Booking not found on an invoice.'; end if;
  if not private.has_permission(b.tenant_id, 'bookings', 'edit') then raise exception 'You don’t have permission to change invoices.'; end if;
  if not exists (select 1 from public.bookings where invoice_id = b.invoice_id and id <> b.id) then
    raise exception 'An invoice needs at least one booking: % is the only one on %.', coalesce(b.order_no, 'this booking'), (select invoice_no from public.invoices where id = b.invoice_id);
  end if;
  update public.bookings set invoice_id = null, paid_amount = 0 where id = b.id;
end $$;

revoke all on function public.invoice_create(uuid[], text, uuid, numeric, jsonb, jsonb) from public, anon;
revoke all on function public.invoice_set_buyer(uuid, jsonb) from public, anon;
grant execute on function public.invoice_create(uuid[], text, uuid, numeric, jsonb, jsonb) to authenticated;
grant execute on function public.invoice_set_buyer(uuid, jsonb) to authenticated;

-- paid can't exceed the total, except while moving old invoices over (bizdock.no_adjust): old totals were rounded
create or replace function private.invoice_recalc(p_inv uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  i   public.invoices;
  a   numeric; g numeric; t numeric;
  d   numeric;
  p   record;
  moving boolean := coalesce(current_setting('bizdock.no_adjust', true), '') = 'on';
begin
  select * into i from public.invoices where id = p_inv;
  if i.id is null then return; end if;
  select coalesce(sum(amount), 0), coalesce(sum(gst_amount), 0), coalesce(sum(total_amount), 0) into a, g, t
    from public.bookings where invoice_id = p_inv and status <> 'cancelled';
  if i.paid_amount > t + 0.01 and not moving then
    raise exception 'Invoice % has % paid, more than its new total %. Change the payments first.',
      i.invoice_no, to_char(i.paid_amount, 'FM₹99,99,99,990.00'), to_char(t, 'FM₹99,99,99,990.00');
  end if;
  d := t - i.total_amount;
  update public.invoices set amount = a, gst_amount = g, total_amount = t where id = p_inv;
  if abs(d) > 0.005 and not moving and exists (select 1 from public.invoice_payments where invoice_id = p_inv) then
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

-- ---------- existing invoices: kind, seller, buyer ----------
update public.invoices i
   set kind = case when i.gst_applicable then 'gst' else 'nongst' end,
       seller = private.seller_of(i.billing_company_id, i.business_id),
       buyer = private.buyer_json(i.client_name, i.phone, '{}'::jsonb)
 where i.seller = '{}'::jsonb;

-- ---------- existing booking invoices (test data): each becomes its own invoice, parts move to it ----------
alter table public.bookings disable trigger bookings_after_save;
do $$
declare b public.bookings; inv uuid;
begin
  for b in select * from public.bookings where invoice_id is null and invoice_no is not null order by created_at loop
    inv := gen_random_uuid();
    insert into public.invoices (id, tenant_id, business_id, sub_business_id, customer_id, lead_id, client_name, phone,
                                 billing_company_id, invoice_no, invoice_date, kind, gst_applicable, gst_rate, seller, buyer, created_by, created_at)
    values (inv, b.tenant_id, b.business_id, b.sub_business_id, b.customer_id, b.lead_id, b.client_name, b.phone,
            b.billing_company_id, b.invoice_no, coalesce(b.invoice_date, b.booking_date), case when b.gst_applicable then 'gst' else 'nongst' end,
            b.gst_applicable, b.gst_rate, private.seller_of(b.billing_company_id, b.business_id), private.buyer_json(b.client_name, b.phone, '{}'::jsonb),
            b.created_by, b.created_at);
    insert into public.invoice_payments (tenant_id, invoice_id, label, amount, due_on, status, paid_on, payment_mode_id, reference, note, received_by, created_at)
    select tenant_id, inv, label, amount, due_on, status, paid_on, payment_mode_id, reference, note, received_by, created_at
      from public.booking_payments where booking_id = b.id;
    perform set_config('bizdock.no_adjust', 'on', true);
    update public.bookings set invoice_id = inv where id = b.id;
    perform set_config('bizdock.no_adjust', '', true);
    delete from public.booking_payments where booking_id = b.id;
    perform private.invoice_allocate(inv);
  end loop;
end $$;
alter table public.bookings enable trigger bookings_after_save;
