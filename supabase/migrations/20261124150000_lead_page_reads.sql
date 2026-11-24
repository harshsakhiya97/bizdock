-- A lead you can see: everything on its page can be read too (meetings, bookings / orders, invoices, payments) — no
-- separate Meetings / Bookings / Payments view permission needed there. The module pages, add / edit / delete keep
-- their own permissions. These are extra read policies: the existing ones stay as they are.

-- the caller can see this lead (same rule as the leads list)
create or replace function private.lead_visible(p_lead uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.leads l
     where l.id = p_lead
       and private.can_see_lead(l.tenant_id, l.business_id, l.owner_id)
       and private.can_access_sub(l.business_id, l.sub_business_id)
  )
$$;

drop policy if exists "meetings: lead page read" on public.meetings;
create policy "meetings: lead page read" on public.meetings for select to authenticated
  using (kind = 'lead' and lead_id is not null and private.lead_visible(lead_id));

drop policy if exists "bookings: lead page read" on public.bookings;
create policy "bookings: lead page read" on public.bookings for select to authenticated
  using (lead_id is not null and private.lead_visible(lead_id));

drop policy if exists "booking_payments: lead page read" on public.booking_payments;
create policy "booking_payments: lead page read" on public.booking_payments for select to authenticated
  using (exists (select 1 from public.bookings b where b.id = booking_id and b.lead_id is not null and private.lead_visible(b.lead_id)));

drop policy if exists "booking_items: lead page read" on public.booking_items;
create policy "booking_items: lead page read" on public.booking_items for select to authenticated
  using (exists (select 1 from public.bookings b where b.id = booking_id and b.lead_id is not null and private.lead_visible(b.lead_id)));

drop policy if exists "invoices: lead page read" on public.invoices;
create policy "invoices: lead page read" on public.invoices for select to authenticated
  using (lead_id is not null and private.lead_visible(lead_id));

drop policy if exists "invoice_payments: lead page read" on public.invoice_payments;
create policy "invoice_payments: lead page read" on public.invoice_payments for select to authenticated
  using (exists (select 1 from public.invoices i where i.id = invoice_id and i.lead_id is not null and private.lead_visible(i.lead_id)));

-- Razorpay payments with the phone / email of a lead the caller can see
create or replace function private.rzp_lead_visible(t uuid, p_phone text, p_email text) returns boolean
language sql stable security definer set search_path = '' as $$
  select (length(private.ph10(p_phone)) = 10 and exists (
            select 1 from public.leads l
             where l.tenant_id = t and private.ph10(l.phone) = private.ph10(p_phone)
               and private.can_see_lead(l.tenant_id, l.business_id, l.owner_id) and private.can_access_sub(l.business_id, l.sub_business_id)))
      or (coalesce(p_email, '') <> '' and exists (
            select 1 from public.leads l
             where l.tenant_id = t and lower(l.email) = lower(p_email)
               and private.can_see_lead(l.tenant_id, l.business_id, l.owner_id) and private.can_access_sub(l.business_id, l.sub_business_id)))
$$;
drop policy if exists "razorpay_payments: lead page read" on public.razorpay_payments;
create policy "razorpay_payments: lead page read" on public.razorpay_payments for select to authenticated
  using (private.is_member(tenant_id) and private.rzp_lead_visible(tenant_id, phone, email));
