-- One studio per business, shared by its Podcast Studio Rental and Paid Podcast sub-businesses.
-- Bookings (not cancelled) in those sub-businesses can't overlap each other; other bookings keep the
-- old rule (confirmed bookings of the business can't overlap).

create or replace function private.is_studio_sub(s uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.sub_businesses x where x.id = s and x.type in ('studio_rental', 'podcast'))
$$;

create or replace function private.booking_before_save()
returns trigger language plpgsql security definer set search_path = '' as $$
declare c record;
begin
  new.gst_amount := case when new.gst_applicable then round(new.amount * new.gst_rate / 100, 2) else 0 end;
  new.total_amount := new.amount + new.gst_amount;

  if new.status <> 'cancelled' and private.is_studio_sub(new.sub_business_id) then
    select b.client_name, b.start_time, b.end_time, s.name as sub_name into c
      from public.bookings b left join public.sub_businesses s on s.id = b.sub_business_id
     where b.business_id = new.business_id and b.booking_date = new.booking_date and b.status <> 'cancelled'
       and b.id <> new.id and private.is_studio_sub(b.sub_business_id)
       and b.start_time < new.end_time and b.end_time > new.start_time
     order by b.start_time limit 1;
    if found then
      raise exception 'Studio not available on % from % to %: booked for % (%).',
        to_char(new.booking_date, 'DD Mon YYYY'), to_char(c.start_time, 'HH12:MI AM'), to_char(c.end_time, 'HH12:MI AM'),
        c.client_name, coalesce(c.sub_name, 'another booking');
    end if;
  elsif new.status = 'confirmed' and exists (
    select 1 from public.bookings b
    where b.business_id = new.business_id and b.booking_date = new.booking_date and b.status = 'confirmed'
      and b.id <> new.id and b.start_time < new.end_time and b.end_time > new.start_time
      and not private.is_studio_sub(b.sub_business_id)
  ) then
    raise exception 'This slot overlaps another confirmed booking on %.', to_char(new.booking_date, 'DD Mon YYYY');
  end if;
  return new;
end $$;

-- Studio bookings of a business (both sub-businesses), for the shared calendar and the clash check.
-- Only what's needed to see the slot: no amounts or payments.
create or replace function public.studio_busy(p_business uuid, p_from date default null, p_to date default null)
returns table (id uuid, sub_business_id uuid, sub_name text, client_name text, purpose text, booking_date date, start_time time, end_time time, status text)
language sql stable security definer set search_path = '' as $$
  select b.id, b.sub_business_id, s.name, b.client_name, b.purpose, b.booking_date, b.start_time, b.end_time, b.status
    from public.bookings b join public.sub_businesses s on s.id = b.sub_business_id
   where b.business_id = p_business and private.can_access_business(p_business)
     and s.type in ('studio_rental', 'podcast') and b.status <> 'cancelled'
     and (p_from is null or b.booking_date >= p_from) and (p_to is null or b.booking_date <= p_to)
$$;
grant execute on function public.studio_busy(uuid, date, date) to authenticated;
