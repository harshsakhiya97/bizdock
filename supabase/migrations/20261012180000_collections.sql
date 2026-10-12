-- ============================================================
-- Collections & EMI: record payments against what is due on a sale.
-- A payment is spread over the sale's pending dues (the picked due first, then by date).
-- TDS deducted by the customer counts towards the balance.
-- Reminders: a due can be marked "reminded" (Done) from the reminders list.
-- Permissions: payments.add (record), payments.verify (mark verified), collections.view (page).
-- ============================================================

alter table public.payments
  add column due_id            uuid references public.sale_dues (id) on delete set null,
  add column gateway_order_id  text,
  add column gateway_charge    numeric(12, 2) not null default 0,
  add column tds_amount        numeric(12, 2) not null default 0 check (tds_amount >= 0),
  add column verified          boolean not null default true,
  add column verified_by       uuid references public.tenant_members (id) on delete set null,
  add column remark            text;

alter table public.sale_dues
  add column reminded_at  timestamptz,
  add column reminded_by  uuid references public.tenant_members (id) on delete set null;

-- what a payment settles = amount received + TDS the customer deducted
create or replace function private.sync_sale_paid()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  sid uuid := coalesce(new.sale_id, old.sale_id);
begin
  update public.sales s
  set paid_amount = coalesce((select sum(p.amount + p.tds_amount) from public.payments p
                              where p.sale_id = sid and p.status = 'received'), 0)
  where s.id = sid;
  return null;
end;
$$;

-- record a payment and settle the sale's dues with it; runs with the caller's rights
create or replace function public.record_payment(p jsonb)
returns uuid
language plpgsql security invoker set search_path = '' as $$
declare
  sale_row   public.sales%rowtype;
  me         uuid;
  pay        uuid := gen_random_uuid();
  amt        numeric := round(coalesce(nullif(p ->> 'amount', '')::numeric, 0), 2);
  tds        numeric := round(coalesce(nullif(p ->> 'tds_amount', '')::numeric, 0), 2);
  first_due  uuid := nullif(p ->> 'due_id', '')::uuid;
  remaining  numeric;
  left_over  numeric;
  d          record;
  take       numeric;
  can_verify boolean;
begin
  select * into sale_row from public.sales where id = (p ->> 'sale_id')::uuid;
  if sale_row.id is null then raise exception 'Pick the sale this payment is for.'; end if;
  if sale_row.status = 'cancelled' then raise exception 'This sale was cancelled.'; end if;
  me := private.my_member_id(sale_row.tenant_id);
  if me is null then raise exception 'You are not part of this workspace.'; end if;
  if not private.has_permission(sale_row.tenant_id, 'payments', 'add') then
    raise exception 'You don’t have permission to record payments.';
  end if;
  if amt <= 0 then raise exception 'Enter the amount received.'; end if;
  if nullif(p ->> 'paid_on', '') is null then raise exception 'Enter the date it was paid.'; end if;
  if nullif(p ->> 'payment_mode_id', '') is null then raise exception 'Pick the payment mode.'; end if;

  remaining := sale_row.total_amount - sale_row.paid_amount;
  if amt + tds > remaining + 0.009 then
    raise exception 'That is more than what is still due on this sale (₹%).', remaining;
  end if;

  can_verify := private.has_permission(sale_row.tenant_id, 'payments', 'verify');

  insert into public.payments (id, tenant_id, sale_id, customer_id, due_id, amount, tds_amount, paid_on, payment_mode_id,
                               billing_company_id, reference, gateway_order_id, gateway_charge, note, remark,
                               received_by, verified, verified_by)
  values (pay, sale_row.tenant_id, sale_row.id, sale_row.customer_id, first_due, amt, tds, (p ->> 'paid_on')::date,
          (p ->> 'payment_mode_id')::uuid,
          coalesce(nullif(p ->> 'billing_company_id', '')::uuid, sale_row.billing_company_id),
          nullif(trim(p ->> 'reference'), ''), nullif(trim(p ->> 'gateway_order_id'), ''),
          coalesce(nullif(p ->> 'gateway_charge', '')::numeric, 0),
          nullif(trim(p ->> 'note'), ''), nullif(trim(p ->> 'remark'), ''),
          coalesce(nullif(p ->> 'received_by', '')::uuid, me),
          can_verify and coalesce((p ->> 'verified')::boolean, true),
          case when can_verify and coalesce((p ->> 'verified')::boolean, true) then me end);

  -- settle dues: the picked one first, then the rest by date
  left_over := amt + tds;
  for d in
    select id, amount, paid_amount from public.sale_dues
    where sale_id = sale_row.id and status = 'pending'
    order by (id = first_due) desc, due_on, seq
  loop
    exit when left_over <= 0;
    take := least(left_over, d.amount - d.paid_amount);
    update public.sale_dues
    set paid_amount = paid_amount + take,
        status = case when paid_amount + take >= amount - 0.009 then 'paid' else 'pending' end
    where id = d.id;
    left_over := left_over - take;
  end loop;

  return pay;
end;
$$;
revoke execute on function public.record_payment(jsonb) from public, anon;
grant execute on function public.record_payment(jsonb) to authenticated;

-- Demo data (Viral): Kunal Shah (EMI, instalment 1 paid, instalment 2 overdue) and Divya Rao (booking, balance overdue), via create_sale / record_payment.
