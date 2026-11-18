-- Lead category rules:
--  * New is only until the first contact: a logged call (follow-up done) or a meeting with the lead makes a New lead Hot
--    (Warm / Cold / Not interested / Closed are never touched).
--  * An order no longer makes the lead Closed (Default / Brand Deals): Closed is marked by the person at the follow-up
--    (a Won stage still makes it Closed, a Lost stage Not interested).
--  * Existing data: New leads that already have a logged call or a meeting become Hot.
create or replace function private.lead_hot_on_contact() returns trigger language plpgsql security definer set search_path to '' as $$
declare lid uuid; t uuid;
begin
  if tg_table_name = 'follow_ups' then
    if new.status <> 'done' or (tg_op = 'UPDATE' and old.status = 'done') then return new; end if;
  end if;
  lid := new.lead_id;
  if lid is null then return new; end if;
  update public.leads set temperature = 'hot' where id = lid and temperature = 'new' returning tenant_id into t;
  if t is not null then
    insert into public.lead_activities (tenant_id, lead_id, kind, note)
    values (t, lid, 'temperature', case when tg_table_name = 'meetings' then 'Hot (meeting scheduled)' else 'Hot (first call)' end);
  end if;
  return new;
end $$;
drop trigger if exists follow_ups_hot_on_contact on public.follow_ups;
create trigger follow_ups_hot_on_contact after insert or update of status on public.follow_ups for each row execute function private.lead_hot_on_contact();
drop trigger if exists meetings_hot_on_contact on public.meetings;
create trigger meetings_hot_on_contact after insert on public.meetings for each row execute function private.lead_hot_on_contact();

update public.leads l set temperature = 'hot'
 where l.temperature = 'new'
   and (exists (select 1 from public.follow_ups f where f.lead_id = l.id and f.status = 'done')
        or exists (select 1 from public.meetings m where m.lead_id = l.id));

create or replace function private.booking_after_save() returns trigger language plpgsql security definer set search_path to '' as $function$
declare
  l    public.leads;
  cid  uuid;
  won  uuid;
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
    -- (an order no longer makes the lead Closed: the person marks Closed at the follow-up)
  end if;
  return new;
end $function$;
