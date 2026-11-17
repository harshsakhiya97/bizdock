-- Deleting a lead / customer deletes their bookings, orders and brand deals too (every business), with the invoices
-- that hold only their bookings (and those invoices' payments). A booking on an invoice shared with someone else's
-- booking just comes off that invoice first.
create or replace function private.lead_delete_bookings()
returns trigger language plpgsql security definer set search_path to '' as $$
begin
  -- invoices that hold only this lead's bookings
  delete from public.invoices i
   where i.id in (select b.invoice_id from public.bookings b where b.lead_id = old.id and b.invoice_id is not null)
     and not exists (select 1 from public.bookings x where x.invoice_id = i.id and x.lead_id is distinct from old.id);
  -- shared invoices: take the bookings off (no payment re-planning while deleting)
  perform set_config('bizdock.no_adjust', 'on', true);
  update public.bookings set invoice_id = null, paid_amount = 0 where lead_id = old.id and invoice_id is not null;
  perform set_config('bizdock.no_adjust', 'off', true);
  delete from public.bookings where lead_id = old.id;
  return old;
end $$;

create trigger leads_delete_bookings before delete on public.leads
  for each row execute function private.lead_delete_bookings();
