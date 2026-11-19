-- Print / PDF on an invoice made before Company Master (no billing company on it): its "From" details come from the
-- business's company for its type (sub-business first, then business; GST → company, without GST → non-GST company),
-- instead of the business's bare name and email. The invoice's number and company link stay as they are.
create or replace function public.invoice_refresh_seller(p_invoice uuid) returns void
language plpgsql security definer set search_path to '' as $$
declare
  i public.invoices;
  co uuid;
begin
  select * into i from public.invoices where id = p_invoice;
  if i.id is null then raise exception 'Invoice not found.'; end if;
  if not (private.has_permission(i.tenant_id, 'bookings', 'edit') or private.has_permission(i.tenant_id, 'bookings', 'add')) then
    raise exception 'You don’t have permission to change invoices.';
  end if;
  co := i.billing_company_id;
  if co is null then
    select case when coalesce(i.kind, case when i.gst_applicable then 'gst' else 'nongst' end) = 'gst' then s.company_id else s.nongst_company_id end
      into co from public.sub_businesses s where s.id = i.sub_business_id;
  end if;
  if co is null then
    select case when coalesce(i.kind, case when i.gst_applicable then 'gst' else 'nongst' end) = 'gst' then b.company_id else b.nongst_company_id end
      into co from public.businesses b where b.id = i.business_id;
  end if;
  update public.invoices set seller = private.seller_of(co, i.business_id) where id = p_invoice;
end $$;
revoke all on function public.invoice_refresh_seller(uuid) from public, anon;
grant execute on function public.invoice_refresh_seller(uuid) to authenticated;
