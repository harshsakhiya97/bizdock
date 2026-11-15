-- Business type DEFAULT: leads, follow-ups and service bookings (no calendar slot) with multipart payments and an invoice
-- from the business's series. A Default booking has no time (start = end); it never clashes with another booking. Its
-- lead becomes a customer (and Closed) once any part is paid, not when it is saved.
create or replace function private.is_default_biz(p_business uuid, p_sub uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select case when p_sub is not null
              then exists (select 1 from public.sub_businesses s where s.id = p_sub and s.type = 'DEFAULT')
              else exists (select 1 from public.businesses b where b.id = p_business and b.type = 'DEFAULT') end
$$;

create or replace function private.booking_before_save() returns trigger
language plpgsql security definer set search_path = '' as $$
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
  elsif new.status = 'confirmed' and new.start_time < new.end_time and not private.is_default_biz(new.business_id, new.sub_business_id) and exists (
    select 1 from public.bookings b
    where b.business_id = new.business_id and b.booking_date = new.booking_date and b.status = 'confirmed'
      and b.id <> new.id and b.start_time < new.end_time and b.end_time > new.start_time
      and not private.is_studio_sub(b.sub_business_id)
  ) then
    raise exception 'This slot overlaps another confirmed booking on %.', to_char(new.booking_date, 'DD Mon YYYY');
  end if;
  return new;
end $$;

create or replace function private.booking_after_save() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  l    public.leads;
  cid  uuid;
  won  uuid;
  dflt boolean := private.is_default_biz(new.business_id, new.sub_business_id);
begin
  if new.status not in ('confirmed', 'completed') then return new; end if;
  -- Default: a customer only once a part is paid
  if dflt and coalesce(new.paid_amount, 0) <= 0 then return new; end if;
  if new.customer_id is null and new.lead_id is not null then
    select * into l from public.leads where id = new.lead_id;
    select id into cid from public.customers where lead_id = new.lead_id and not is_archived limit 1;
    if cid is null then
      insert into public.customers (tenant_id, business_id, lead_id, full_name, phone, email, city, stage_id, owner_id, created_by)
      values (new.tenant_id, new.business_id, new.lead_id, trim(concat_ws(' ', l.first_name, l.last_name)), l.phone, l.email, l.city,
              (select id from public.customer_stages where tenant_id = new.tenant_id and is_active order by sort_order limit 1),
              coalesce(l.owner_id, new.owner_id), new.created_by)
      returning id into cid;
    end if;
    update public.bookings set customer_id = cid where id = new.id;
  end if;
  if new.lead_id is not null then
    select * into l from public.leads where id = new.lead_id;
    if l.funnel_id is not null then
      select id into won from public.funnel_stages where funnel_id = l.funnel_id and kind = 'won' order by sort_order limit 1;
      if won is not null and l.stage_id is distinct from won then
        update public.leads set stage_id = won where id = l.id;
        insert into public.lead_activities (tenant_id, lead_id, kind, from_stage_id, to_stage_id, note, member_id)
        values (l.tenant_id, l.id, 'stage', l.stage_id, won, 'Booked ' || to_char(new.booking_date, 'DD Mon') , new.created_by);
      end if;
    end if;
    if dflt then update public.leads set temperature = 'closed' where id = new.lead_id and temperature is distinct from 'closed'; end if;
  end if;
  return new;
end $$;

drop trigger if exists bookings_after_save on public.bookings;
create trigger bookings_after_save after insert or update of status, lead_id, paid_amount on public.bookings
  for each row execute function private.booking_after_save();

-- DEFAULT is a system type of every workspace (first in the list; new businesses start with it)
create or replace function private.seed_business_types(t uuid) returns void
language sql security definer set search_path = '' as $$
  insert into public.business_types (tenant_id, code, name, is_system, sort_order) values
    (t, 'DEFAULT', 'Default', true, 0),
    (t, 'EDITING', 'Editing service', true, 1),
    (t, 'PAID-PODCAST', 'Podcast', true, 2),
    (t, 'STUDIO-RENTAL', 'Podcast studio rental', true, 3)
  on conflict (tenant_id, code) do nothing
$$;
insert into public.business_types (tenant_id, code, name, is_system, sort_order)
select t.id, 'DEFAULT', 'Default', true, 0 from public.tenants t
on conflict (tenant_id, code) do nothing;
update public.business_types set is_system = true, sort_order = 0 where code = 'DEFAULT';
