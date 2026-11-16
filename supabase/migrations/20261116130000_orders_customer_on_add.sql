-- Default / Brand Deals: adding an order (not cancelled) makes its lead a customer and Closed, paid or not
-- (before: only once a part was paid). Orders already added are re-run so their leads become customers.
create or replace function private.booking_after_save() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  l    public.leads;
  cid  uuid;
  won  uuid;
  dflt boolean := private.is_default_biz(new.business_id, new.sub_business_id);
begin
  if new.status not in ('confirmed', 'completed') then return new; end if;
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
update public.bookings b set status = b.status
 where b.status in ('confirmed', 'completed') and b.lead_id is not null and b.customer_id is null
   and private.is_default_biz(b.business_id, b.sub_business_id);
