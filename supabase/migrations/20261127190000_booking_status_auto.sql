-- Studio bookings have 3 statuses: Confirmed (when booked), Completed (by itself once the booking's end time has passed —
-- never marked by hand) and Cancelled (only before the start time). Tentative is gone: the one tentative booking is
-- treated as confirmed. Orders (order_no) are not touched — they have their own status.
set local lock_timeout = '15s';

create or replace function private.booking_status_rules() returns trigger
language plpgsql set search_path = '' as $$
declare
  st timestamptz := (new.booking_date + coalesce(new.start_time, time '00:00')) at time zone 'Asia/Kolkata';
  en timestamptz := (new.booking_date + coalesce(new.end_time, time '23:59')) at time zone 'Asia/Kolkata';
begin
  if new.order_no is not null then return new; end if;
  if new.status = 'tentative' then new.status := 'confirmed'; end if;
  if tg_op = 'UPDATE' and new.status is not distinct from old.status then
    -- moved to a later time: a completed booking is confirmed again until it ends
    if new.status = 'completed' and en > now() then new.status := 'confirmed'; end if;
    return new;
  end if;
  if new.status = 'completed' and en > now() then
    raise exception 'A booking is completed by itself once it ends — it can’t be marked completed before %.', to_char(en at time zone 'Asia/Kolkata', 'DD Mon, HH12:MI am');
  end if;
  if new.status = 'cancelled' and st <= now() and (tg_op = 'INSERT' or old.status is distinct from 'cancelled') then
    raise exception 'This booking has already started — it can only be cancelled before its start time.';
  end if;
  if tg_op = 'UPDATE' and old.status = 'completed' and new.status <> 'completed' then
    raise exception 'This booking is completed — its status can’t be changed.';
  end if;
  return new;
end $$;
drop trigger if exists bookings_status_rules on public.bookings;
create trigger bookings_status_rules before insert or update on public.bookings
  for each row execute function private.booking_status_rules();

-- every 5 minutes: confirmed bookings whose end has passed become completed
create or replace function private.bookings_complete_ended() returns void
language sql security definer set search_path = '' as $$
  update public.bookings set status = 'completed'
   where order_no is null and status in ('confirmed', 'tentative')
     and ((booking_date + coalesce(end_time, time '23:59')) at time zone 'Asia/Kolkata') <= now()
$$;
select cron.schedule('bookings-complete', '*/5 * * * *', 'select private.bookings_complete_ended()');

update public.bookings set status = 'confirmed' where status = 'tentative' and order_no is null;
select private.bookings_complete_ended();
