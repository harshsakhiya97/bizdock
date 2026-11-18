-- Print / PDF regenerates the invoice: its "From (company)" details are taken again from the company in Masters
-- (name, address, GSTIN, bank…), in case they changed after the invoice was made. The number, type and amounts stay.
create or replace function public.invoice_refresh_seller(p_invoice uuid) returns void
language plpgsql security definer set search_path to '' as $$
declare i public.invoices;
begin
  select * into i from public.invoices where id = p_invoice;
  if i.id is null then raise exception 'Invoice not found.'; end if;
  if not (private.has_permission(i.tenant_id, 'bookings', 'edit') or private.has_permission(i.tenant_id, 'bookings', 'add')) then
    raise exception 'You don’t have permission to change invoices.';
  end if;
  update public.invoices set seller = private.seller_of(i.billing_company_id, i.business_id) where id = p_invoice;
end $$;
revoke all on function public.invoice_refresh_seller(uuid) from public, anon;
grant execute on function public.invoice_refresh_seller(uuid) to authenticated;
