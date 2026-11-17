-- Delete a booking / order / brand deal (Bookings list → 🗑, with a confirm).
-- On its own invoice: that invoice (and its payments) goes too. On a shared invoice: it comes off it first
-- (the invoice total drops; refused while more is paid than the new total).
create or replace function public.booking_delete(p_id uuid)
returns void language plpgsql security definer set search_path to '' as $$
declare b public.bookings; v_others int;
begin
  select * into b from public.bookings where id = p_id;
  if b.id is null or not private.can_see_booking(b.id) then raise exception 'Booking not found.'; end if;
  if not private.has_permission(b.tenant_id, 'bookings', 'delete') then raise exception 'Your role can’t delete bookings.'; end if;
  if b.invoice_id is not null then
    select count(*) into v_others from public.bookings where invoice_id = b.invoice_id and id <> b.id;
    if v_others = 0 then
      delete from public.invoices where id = b.invoice_id;
    else
      update public.bookings set invoice_id = null, paid_amount = 0 where id = b.id;
    end if;
  end if;
  delete from public.bookings where id = b.id;
end $$;
revoke all on function public.booking_delete(uuid) from public, anon;
grant execute on function public.booking_delete(uuid) to authenticated;
