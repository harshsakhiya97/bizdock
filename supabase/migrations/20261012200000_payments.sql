-- ============================================================
-- Payments: verify and cancel payments; dues are re-settled from the payments that remain.
--   kind 'initial'    = taken when the sale was created (full amount / token / down payment)
--   kind 'collection' = recorded later against the dues (Collections & EMI)
-- A cancelled collection payment is taken off its dues again. Initial payments can't be
-- cancelled on their own (cancel the sale instead).
-- ============================================================

alter table public.payments
  add column kind           text not null default 'initial' check (kind in ('initial', 'collection')),
  add column cancel_reason  text,
  add column cancelled_at   timestamptz,
  add column cancelled_by   uuid references public.tenant_members (id) on delete set null;

-- payments recorded through Collections so far (applied with execute_sql):
--   update public.payments set kind = 'collection' where due_id is not null or note = 'EMI 1';

-- settle a sale's dues again from its collection payments (oldest first, each one's picked due first)
create or replace function private.reapply_dues(s uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  pay   record;
  d     record;
  left_over numeric;
  take  numeric;
begin
  update public.sale_dues set paid_amount = 0, status = 'pending' where sale_id = s and status <> 'cancelled';
  for pay in
    select id, due_id, amount + tds_amount as total from public.payments
    where sale_id = s and kind = 'collection' and status = 'received'
    order by paid_on, created_at
  loop
    left_over := pay.total;
    for d in
      select id, amount, paid_amount from public.sale_dues
      where sale_id = s and status = 'pending'
      order by (id = pay.due_id) desc nulls last, due_on, seq
    loop
      exit when left_over <= 0;
      take := least(left_over, d.amount - d.paid_amount);
      update public.sale_dues
      set paid_amount = paid_amount + take,
          status = case when paid_amount + take >= amount - 0.009 then 'paid' else 'pending' end
      where id = d.id;
      left_over := left_over - take;
    end loop;
  end loop;
end;
$$;

-- record_payment: same checks as before; the payment is a 'collection' and dues are re-settled
create or replace function public.record_payment(p jsonb)
returns uuid
language plpgsql security invoker set search_path = '' as $$
declare
  sale_row   public.sales%rowtype;
  me         uuid;
  pay        uuid := gen_random_uuid();
  amt        numeric := round(coalesce(nullif(p ->> 'amount', '')::numeric, 0), 2);
  tds        numeric := round(coalesce(nullif(p ->> 'tds_amount', '')::numeric, 0), 2);
  remaining  numeric;
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

  insert into public.payments (id, tenant_id, sale_id, customer_id, due_id, kind, amount, tds_amount, paid_on, payment_mode_id,
                               billing_company_id, reference, gateway_order_id, gateway_charge, note, remark,
                               received_by, verified, verified_by)
  values (pay, sale_row.tenant_id, sale_row.id, sale_row.customer_id, nullif(p ->> 'due_id', '')::uuid, 'collection',
          amt, tds, (p ->> 'paid_on')::date, (p ->> 'payment_mode_id')::uuid,
          coalesce(nullif(p ->> 'billing_company_id', '')::uuid, sale_row.billing_company_id),
          nullif(trim(p ->> 'reference'), ''), nullif(trim(p ->> 'gateway_order_id'), ''),
          coalesce(nullif(p ->> 'gateway_charge', '')::numeric, 0),
          nullif(trim(p ->> 'note'), ''), nullif(trim(p ->> 'remark'), ''),
          coalesce(nullif(p ->> 'received_by', '')::uuid, me),
          can_verify and coalesce((p ->> 'verified')::boolean, true),
          case when can_verify and coalesce((p ->> 'verified')::boolean, true) then me end);

  perform private.reapply_dues(sale_row.id);
  return pay;
end;
$$;

-- cancel a collection payment (with a reason); its amount goes back onto the dues
create or replace function public.cancel_payment(p_id uuid, p_reason text)
returns void
language plpgsql security invoker set search_path = '' as $$
declare
  pay public.payments%rowtype;
begin
  select * into pay from public.payments where id = p_id;
  if pay.id is null then raise exception 'Payment not found.'; end if;
  if pay.status = 'cancelled' then raise exception 'This payment is already cancelled.'; end if;
  if pay.kind = 'initial' then
    raise exception 'This was paid when the sale was made. Cancel the sale instead.';
  end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Give a reason.'; end if;
  if not (private.has_permission(pay.tenant_id, 'payments', 'verify') or private.has_permission(pay.tenant_id, 'deals', 'edit')) then
    raise exception 'You don’t have permission to cancel payments.';
  end if;
  update public.payments
  set status = 'cancelled', cancel_reason = trim(p_reason), cancelled_at = now(),
      cancelled_by = private.my_member_id(pay.tenant_id)
  where id = p_id;
  perform private.reapply_dues(pay.sale_id);
end;
$$;

-- verify a payment that was waiting
create or replace function public.verify_payment(p_id uuid)
returns void
language plpgsql security invoker set search_path = '' as $$
declare
  t uuid;
begin
  select tenant_id into t from public.payments where id = p_id;
  if t is null then raise exception 'Payment not found.'; end if;
  if not private.has_permission(t, 'payments', 'verify') then
    raise exception 'You don’t have permission to verify payments.';
  end if;
  update public.payments set verified = true, verified_by = private.my_member_id(t) where id = p_id and status = 'received';
end;
$$;

revoke execute on all functions in schema private from public, anon;
grant execute on all functions in schema private to authenticated;
revoke execute on function public.record_payment(jsonb), public.cancel_payment(uuid, text), public.verify_payment(uuid) from public, anon;
grant execute on function public.record_payment(jsonb), public.cancel_payment(uuid, text), public.verify_payment(uuid) to authenticated;

-- Demo data (Viral): Rohan recorded ₹8,000 of Divya Rao's balance by bank transfer (waiting for verification).
