-- Edit invoice: change With GST / Without GST, the company (From) and the GST %. A new company gives the invoice that
-- company's next number; the bookings take the GST change (their totals and the invoice's follow, the pending parts
-- move with it). Returns the invoice number.
create or replace function public.invoice_set_kind(p_invoice uuid, p_kind text, p_company uuid, p_rate numeric)
returns text language plpgsql security definer set search_path = '' as $$
declare
  i public.invoices;
  comp uuid;
  no text;
  rate numeric;
begin
  select * into i from public.invoices where id = p_invoice;
  if i.id is null then raise exception 'Invoice not found.'; end if;
  if not (private.has_permission(i.tenant_id, 'bookings', 'edit') or private.has_permission(i.tenant_id, 'bookings', 'add')) then
    raise exception 'You don’t have permission to change invoices.';
  end if;
  if p_kind not in ('gst', 'nongst') then raise exception 'Pick With GST or Without GST.'; end if;
  select id into comp from public.billing_companies where id = p_company and tenant_id = i.tenant_id;
  if comp is null then
    select case when p_kind = 'gst' then s.company_id else s.nongst_company_id end into comp from public.sub_businesses s where s.id = i.sub_business_id;
  end if;
  if comp is null then
    select case when p_kind = 'gst' then b.company_id else b.nongst_company_id end into comp from public.businesses b where b.id = i.business_id;
  end if;
  rate := case when p_kind = 'gst' then coalesce(nullif(p_rate, 0), i.gst_rate, 18) else i.gst_rate end;
  if p_kind = coalesce(i.kind, case when i.gst_applicable then 'gst' else 'nongst' end)
     and comp is not distinct from i.billing_company_id and rate = i.gst_rate then
    return i.invoice_no;
  end if;
  no := i.invoice_no;
  if comp is distinct from i.billing_company_id then no := private.next_invoice_no(i.business_id, comp); end if;
  update public.invoices
     set kind = p_kind, gst_applicable = (p_kind = 'gst'), gst_rate = rate, billing_company_id = comp,
         seller = private.seller_of(comp, i.business_id), invoice_no = no
   where id = p_invoice;
  return no;
end $$;
revoke all on function public.invoice_set_kind(uuid, text, uuid, numeric) from public, anon;
grant execute on function public.invoice_set_kind(uuid, text, uuid, numeric) to authenticated;
