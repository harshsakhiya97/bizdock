-- Orders (Default businesses): a booking without a time (start = end) is an order — ORD-0001… per business (never
-- reset), its own status (not started / active / completed / cancelled), one invoice and payment parts as before.
alter table public.bookings drop constraint if exists bookings_check;
alter table public.bookings add constraint bookings_check check (end_time >= start_time);

alter table public.bookings
  add column if not exists order_no text,
  add column if not exists order_status text check (order_status in ('not_started', 'active', 'completed', 'cancelled'));
create unique index if not exists bookings_order_no_key on public.bookings (business_id, order_no) where order_no is not null;

create table if not exists private.order_counters (business_id uuid primary key, last_no int not null default 0);

create or replace function private.booking_order() returns trigger
language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  if private.is_default_biz(new.business_id, new.sub_business_id) then
    if new.order_status is null then new.order_status := 'not_started'; end if;
    if new.order_no is null then
      insert into private.order_counters as c (business_id, last_no) values (new.business_id, 1)
      on conflict (business_id) do update set last_no = c.last_no + 1
      returning last_no into n;
      new.order_no := 'ORD-' || lpad(n::text, 4, '0');
    end if;
    -- the booking status follows the order: cancelled, else confirmed (invoice, customer and totals work as before)
    new.status := case when new.order_status = 'cancelled' then 'cancelled' else 'confirmed' end;
  end if;
  return new;
end $$;
drop trigger if exists bookings_order on public.bookings;
create trigger bookings_order before insert or update of order_status, business_id, sub_business_id on public.bookings
  for each row execute function private.booking_order();
