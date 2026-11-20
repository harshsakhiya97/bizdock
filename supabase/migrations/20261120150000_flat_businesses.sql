-- One level of businesses: every sub-business becomes a business of its own (same id), its records move with it, and
-- the old parent businesses (TVS in Pride, Studio Rental in Viral) are switched off (kept, hidden). Nothing is deleted:
-- the sub_businesses rows stay (switched off) and so does the parent.
--   * leads / bookings / meetings / invoices / funnels / products / sales / calls / ad spend: business = their sub-business
--   * a lead in a funnel goes where its funnel goes (a lead and its funnel are always in the same business)
--   * records the parent had without a sub-business: TVS → Paid Podcast, Viral's Studio Rental → Studio Hire
--   * team access: a member who had the parent gets each of its sub-businesses they could see
--   * billing companies: the sub-business's own, else the parent's
-- Studio Rental and Paid Podcast share one studio, so the "studio is booked" check now runs across the workspace's studio
-- businesses (it used to run inside one business). Invoice numbers always come from a billing company (Company master).

-- ---------- 1. the new businesses ----------
create temporary table _flat on commit drop as
select s.id as sub_id, s.business_id as parent_id, s.tenant_id
  from public.sub_businesses s
 where s.is_active and not exists (select 1 from public.businesses b where b.id = s.id);

-- leftovers of a parent (records without a sub-business) go here
create temporary table _leftover on commit drop as
select p.parent_id,
       coalesce(
         (select s.id from public.sub_businesses s where s.id = '561b4e25-4923-4c5c-a7e2-b76a8c6679bd' and s.business_id = p.parent_id), -- TVS → Paid Podcast
         (select s.id from public.sub_businesses s where s.id = '35ac18b5-51b6-4c7d-aaa4-bbbafd76568f' and s.business_id = p.parent_id), -- Studio Rental → Studio Hire
         (select s.id from public.sub_businesses s where s.business_id = p.parent_id and s.is_active order by s.sort_order limit 1)
       ) as to_id
  from (select distinct parent_id from _flat) p;

-- keep the order: parents' places stay, their sub-businesses take the parent's place
update public.businesses set sort_order = sort_order * 100 where tenant_id in (select tenant_id from _flat);

insert into public.businesses (id, tenant_id, name, is_active, sort_order, created_at, logo_url, phone, email, address, city, state, gst_number,
                               legal_name, has_branches, has_gst, has_sub_businesses, type, company_id, nongst_company_id)
select s.id, s.tenant_id, s.name, true, p.sort_order + s.sort_order, s.created_at, p.logo_url, p.phone, p.email, p.address, p.city, p.state,
       p.gst_number, p.legal_name, false, p.has_gst, false, s.type, coalesce(s.company_id, p.company_id), coalesce(s.nongst_company_id, p.nongst_company_id)
  from _flat f join public.sub_businesses s on s.id = f.sub_id join public.businesses p on p.id = f.parent_id;

-- ---------- 2. records move (row triggers off while moving: nothing about them changes but the business) ----------
alter table public.leads disable trigger user;
alter table public.bookings disable trigger user;
alter table public.invoices disable trigger user;
alter table public.funnels disable trigger user;
alter table public.leads drop constraint leads_funnel_id_business_id_fkey;

-- funnels first (leads follow them)
update public.funnels x set business_id = x.sub_business_id, sub_business_id = null
 where x.sub_business_id in (select sub_id from _flat);
update public.funnels x set business_id = l.to_id from _leftover l where x.business_id = l.parent_id;

-- leads: their funnel's business, else their sub-business, else the leftover business
update public.leads x set business_id = f.business_id, sub_business_id = null
  from public.funnels f where x.funnel_id = f.id and x.business_id in (select parent_id from _leftover);
update public.leads x set business_id = x.sub_business_id, sub_business_id = null
 where x.sub_business_id in (select sub_id from _flat);
update public.leads x set business_id = l.to_id, sub_business_id = null from _leftover l where x.business_id = l.parent_id;

alter table public.leads add constraint leads_funnel_id_business_id_fkey foreign key (funnel_id, business_id) references public.funnels (id, business_id) on delete cascade;

do $$
declare t text;
begin
  foreach t in array array['bookings', 'meetings', 'invoices', 'products', 'sales', 'calls', 'ad_spend'] loop
    execute format('update public.%I x set business_id = x.sub_business_id, sub_business_id = null where x.sub_business_id in (select sub_id from _flat)', t);
    execute format('update public.%I x set business_id = l.to_id, sub_business_id = null from _leftover l where x.business_id = l.parent_id', t);
  end loop;
end $$;

update public.events x set business_id = l.to_id from _leftover l where x.business_id = l.parent_id;
-- customers (the old customer list): with their lead
update public.customers c set business_id = l.business_id from public.leads l where c.lead_id = l.id and c.business_id <> l.business_id;

alter table public.leads enable trigger user;
alter table public.bookings enable trigger user;
alter table public.invoices enable trigger user;
alter table public.funnels enable trigger user;

-- ---------- 3. team access ----------
insert into public.member_businesses (member_id, business_id, tenant_id)
select mb.member_id, f.sub_id, mb.tenant_id
  from public.member_businesses mb join _flat f on f.parent_id = mb.business_id
 where coalesce(cardinality(mb.sub_business_ids), 0) = 0 or f.sub_id = any (mb.sub_business_ids)
on conflict do nothing;

-- ---------- 4. the old level switched off (kept) ----------
update public.sub_businesses set is_active = false where id in (select sub_id from _flat);
update public.businesses set is_active = false, archived_at = coalesce(archived_at, now()) where id in (select parent_id from _flat);

-- ---------- 5. studio: one studio across the workspace's Studio Rental and Paid Podcast businesses ----------
create or replace function private.is_studio_biz(p_business uuid, p_sub uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce(
    (select x.type from public.sub_businesses x where x.id = p_sub),
    (select b.type from public.businesses b where b.id = p_business)
  ) in ('studio_rental', 'podcast', 'STUDIO-RENTAL', 'PAID-PODCAST')
$$;

create or replace function private.booking_before_save() returns trigger
language plpgsql security definer set search_path = '' as $function$
declare c record;
begin
  new.gst_amount := case when new.gst_applicable then round(new.amount * new.gst_rate / 100, 2) else 0 end;
  new.total_amount := new.amount + new.gst_amount;

  if new.status <> 'cancelled' and private.is_studio_biz(new.business_id, new.sub_business_id) then
    select b.client_name, b.start_time, b.end_time, coalesce(s.name, bz.name) as sub_name into c
      from public.bookings b
      left join public.sub_businesses s on s.id = b.sub_business_id
      join public.businesses bz on bz.id = b.business_id
     where b.tenant_id = new.tenant_id and b.booking_date = new.booking_date and b.status <> 'cancelled'
       and b.id <> new.id and private.is_studio_biz(b.business_id, b.sub_business_id)
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
      and not private.is_studio_biz(b.business_id, b.sub_business_id)
  ) then
    raise exception 'This slot overlaps another confirmed booking on %.', to_char(new.booking_date, 'DD Mon YYYY');
  end if;
  return new;
end $function$;

-- the studio's bookings (every studio business of the workspace); sub_business_id / sub_name = the business that booked it
create or replace function public.studio_busy(p_business uuid, p_from date default null, p_to date default null)
returns table(id uuid, sub_business_id uuid, sub_name text, client_name text, purpose text, booking_date date, start_time time, end_time time, status text)
language sql stable security definer set search_path = '' as $$
  select b.id, coalesce(b.sub_business_id, b.business_id), coalesce(s.name, bz.name), b.client_name, b.purpose, b.booking_date, b.start_time, b.end_time, b.status
    from public.bookings b
    join public.businesses me on me.id = p_business
    join public.businesses bz on bz.id = b.business_id
    left join public.sub_businesses s on s.id = b.sub_business_id
   where b.tenant_id = me.tenant_id and private.can_access_business(p_business)
     and private.is_studio_biz(b.business_id, b.sub_business_id) and b.status <> 'cancelled'
     and (p_from is null or b.booking_date >= p_from) and (p_to is null or b.booking_date <= p_to)
$$;

-- ---------- 6. invoice numbers: always from a billing company ----------
create or replace function private.next_invoice_no(p_business uuid, p_company uuid) returns text
language plpgsql security definer set search_path = '' as $function$
declare co uuid;
begin
  select id into co from public.billing_companies where id = p_company;
  if co is null then
    select coalesce(b.company_id, b.nongst_company_id) into co from public.businesses b where b.id = p_business;
  end if;
  if co is null then
    raise exception 'Pick a billing company for this business first (Settings → Businesses): invoice numbers come from the company.';
  end if;
  return private.company_next_no(co);
end $function$;

create or replace function public.invoice_create(p_orders uuid[], p_kind text, p_company uuid, p_rate numeric, p_buyer jsonb, p_parts jsonb)
returns uuid language plpgsql security definer set search_path = '' as $function$
declare
  f    public.bookings;
  none public.invoices;
  inv  uuid := gen_random_uuid();
  comp uuid;
  me   uuid;
  tot  numeric;
  planned numeric;
  p    jsonb;
  buyer jsonb;
begin
  if p_kind not in ('gst', 'nongst') then raise exception 'Pick With GST or Without GST.'; end if;
  f := private.check_orders(p_orders, none);
  if not (private.has_permission(f.tenant_id, 'bookings', 'add') or private.has_permission(f.tenant_id, 'bookings', 'edit')) then
    raise exception 'You don’t have permission to create invoices.';
  end if;
  me := private.my_member_id(f.tenant_id);
  select id into comp from public.billing_companies where id = p_company and tenant_id = f.tenant_id;
  -- no company picked: the business's company for this kind
  if comp is null then
    select case when p_kind = 'gst' then b.company_id else b.nongst_company_id end into comp from public.businesses b where b.id = f.business_id;
  end if;
  buyer := private.buyer_json(f.client_name, f.phone, coalesce(p_buyer, '{}'::jsonb));
  insert into public.invoices (id, tenant_id, business_id, sub_business_id, customer_id, lead_id, client_name, phone,
                               billing_company_id, invoice_no, kind, gst_applicable, gst_rate, seller, buyer, created_by)
  values (inv, f.tenant_id, f.business_id, f.sub_business_id, f.customer_id, f.lead_id, f.client_name, f.phone,
          comp, private.next_invoice_no(f.business_id, comp), p_kind, p_kind = 'gst', coalesce(p_rate, 18),
          private.seller_of(comp, f.business_id), buyer, me);
  if f.lead_id is not null then perform private.save_lead_billing(f.lead_id, buyer); end if;
  perform set_config('bizdock.no_adjust', 'on', true);
  update public.bookings set invoice_id = inv where id = any(p_orders);
  perform set_config('bizdock.no_adjust', '', true);
  select total_amount into tot from public.invoices where id = inv;
  select coalesce(sum((x->>'amount')::numeric), 0) into planned from jsonb_array_elements(coalesce(p_parts, '[]'::jsonb)) x;
  if planned > tot + 0.01 then
    raise exception 'The payment parts add up to %, more than the invoice total %.', to_char(planned, 'FM₹99,99,99,990.00'), to_char(tot, 'FM₹99,99,99,990.00');
  end if;
  for p in select * from jsonb_array_elements(coalesce(p_parts, '[]'::jsonb)) loop
    if coalesce((p->>'amount')::numeric, 0) <= 0 then continue; end if;
    insert into public.invoice_payments (tenant_id, invoice_id, label, amount, due_on, status, paid_on, payment_mode_id, note, received_by)
    values (f.tenant_id, inv, coalesce(nullif(trim(p->>'label'), ''), 'Payment'), (p->>'amount')::numeric, nullif(p->>'due_on', '')::date,
            case when p->>'status' = 'paid' then 'paid' else 'pending' end,
            case when p->>'status' = 'paid' then coalesce(nullif(p->>'paid_on', '')::date, current_date) end,
            (select id from public.payment_modes where id = nullif(p->>'mode', '')::uuid and tenant_id = f.tenant_id),
            nullif(trim(p->>'note'), ''), case when p->>'status' = 'paid' then me end);
  end loop;
  return inv;
end $function$;

-- the old per-booking number (bookings.invoice_no): from the booking's company, else the business's; none → no number
create or replace function private.assign_booking_invoice(p_booking uuid) returns void
language plpgsql security definer set search_path = '' as $function$
declare
  b     public.bookings;
  c     public.billing_companies;
  v_fy  text;
  n     int;
begin
  select * into b from public.bookings where id = p_booking;
  if b.id is null or b.invoice_no is not null or b.status = 'cancelled' then return; end if;
  if private.is_default_biz(b.business_id, b.sub_business_id) then return; end if;
  select * into c from public.billing_companies
   where id = coalesce(b.billing_company_id, (select case when b.gst_applicable then coalesce(z.company_id, z.nongst_company_id) else coalesce(z.nongst_company_id, z.company_id) end
                                                from public.businesses z where z.id = b.business_id));
  if c.id is null then return; end if;
  v_fy := case when extract(month from coalesce(b.created_at, now())) >= 4
               then to_char(coalesce(b.created_at, now()), 'YY') || '-' || to_char(coalesce(b.created_at, now()) + interval '1 year', 'YY')
               else to_char(coalesce(b.created_at, now()) - interval '1 year', 'YY') || '-' || to_char(coalesce(b.created_at, now()), 'YY') end;
  insert into public.invoice_counters as ic (billing_company_id, fy, last_no) values (c.id, v_fy, 1)
  on conflict (billing_company_id, fy) do update set last_no = ic.last_no + 1 returning ic.last_no into n;
  update public.bookings set invoice_no = coalesce(nullif(c.invoice_prefix, ''), 'INV') || '/' || v_fy || '/' || lpad(n::text, 4, '0'),
                             invoice_date = coalesce(b.created_at::date, current_date) where id = b.id;
end $function$;
