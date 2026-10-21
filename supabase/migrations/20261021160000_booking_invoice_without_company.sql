-- A booking invoice no longer needs a billing company (it was removed from the booking form):
-- without one it is numbered per business (INV/26-27/0001) and the invoice shows the business details.
create table public.business_invoice_counters (
  business_id uuid not null references public.businesses (id) on delete cascade,
  fy          text not null,
  last_no     int  not null default 0,
  primary key (business_id, fy)
);
alter table public.business_invoice_counters enable row level security;
revoke all on public.business_invoice_counters from anon, authenticated;

create or replace function public.booking_invoice(p_booking uuid, p_company uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  b     public.bookings;
  c     public.billing_companies;
  v_fy  text;
  n     int;
  v_no  text;
begin
  select * into b from public.bookings where id = p_booking;
  if b.id is null or not private.can_see_booking(b.id) then raise exception 'Booking not found.'; end if;
  if not private.has_permission(b.tenant_id, 'bookings', 'edit') then raise exception 'You don’t have permission to create invoices.'; end if;
  if b.invoice_no is not null then return b.invoice_no; end if;
  if b.status = 'cancelled' then raise exception 'A cancelled booking has no invoice.'; end if;
  select * into c from public.billing_companies where id = coalesce(p_company, b.billing_company_id) and tenant_id = b.tenant_id;
  v_fy := case when extract(month from current_date) >= 4
               then to_char(current_date, 'YY') || '-' || to_char(current_date + interval '1 year', 'YY')
               else to_char(current_date - interval '1 year', 'YY') || '-' || to_char(current_date, 'YY') end;
  if c.id is not null then
    insert into public.invoice_counters as ic (billing_company_id, fy, last_no) values (c.id, v_fy, 1)
    on conflict (billing_company_id, fy) do update set last_no = ic.last_no + 1
    returning ic.last_no into n;
    v_no := coalesce(nullif(c.invoice_prefix, ''), 'INV') || '/' || v_fy || '/' || lpad(n::text, 4, '0');
  else
    insert into public.business_invoice_counters as bc (business_id, fy, last_no) values (b.business_id, v_fy, 1)
    on conflict (business_id, fy) do update set last_no = bc.last_no + 1
    returning bc.last_no into n;
    v_no := 'INV/' || v_fy || '/' || lpad(n::text, 4, '0');
  end if;
  update public.bookings set invoice_no = v_no, invoice_date = current_date, billing_company_id = c.id where id = b.id;
  return v_no;
end;
$$;
