-- Dashboard (owner), one business picked: lead quality, speed to the first call, call outcomes, meetings, billing, bookings / orders
create or replace function public.owner_business_focus(p_tenant uuid, p_business uuid, p_from date, p_to date)
returns jsonb
language sql stable security definer set search_path = '' as $$
  with b as (
    select (p_from::timestamp at time zone 'Asia/Kolkata') d0, ((p_to + 1)::timestamp at time zone 'Asia/Kolkata') d1
     where private.is_owner_view(p_tenant) and exists (select 1 from public.businesses x where x.id = p_business and x.tenant_id = p_tenant)
  ),
  ld as (
    select l.id, l.temperature, l.created_at
      from public.leads l, b
     where l.tenant_id = p_tenant and l.business_id = p_business and not coalesce(l.is_archived, false) and l.created_at >= b.d0 and l.created_at < b.d1
  ),
  first_touch as (
    select ld.id, ld.created_at,
           least((select min(f.completed_at) from public.follow_ups f where f.lead_id = ld.id and f.status = 'done'),
                 (select min(c.started_at) from public.calls c where c.lead_id = ld.id)) touched
      from ld
  ),
  inv as (
    select i.id, i.client_name, i.total_amount, i.paid_amount
      from public.invoices i where i.tenant_id = p_tenant and i.business_id = p_business and i.invoice_date between p_from and p_to
  ),
  mt as (
    select m.status from public.meetings m where m.tenant_id = p_tenant and m.business_id = p_business and m.meeting_date between p_from and p_to
  ),
  bk as (
    select k.status, k.total_amount, k.start_time, k.end_time
      from public.bookings k where k.tenant_id = p_tenant and k.business_id = p_business and k.order_no is null and k.booking_date between p_from and p_to
  ),
  ord as (
    select coalesce(k.order_status, 'not_started') st, k.total_amount
      from public.bookings k where k.tenant_id = p_tenant and k.business_id = p_business and k.order_no is not null
       and (k.created_at at time zone 'Asia/Kolkata')::date between p_from and p_to
  ),
  outc as (
    select coalesce(o.name, 'No outcome') name, count(*) n
      from public.follow_ups f join public.leads l on l.id = f.lead_id left join public.follow_up_outcomes o on o.id = f.outcome_id, b
     where f.tenant_id = p_tenant and l.business_id = p_business and f.status = 'done' and f.completed_at >= b.d0 and f.completed_at < b.d1
     group by 1
  )
  select case when not exists (select 1 from b) then null else jsonb_build_object(
    'categories', coalesce((select jsonb_object_agg(coalesce(temperature, 'new'), n) from (select temperature, count(*) n from ld group by 1) x), '{}'::jsonb),
    'first_touch', jsonb_build_object(
      'median_min', (select round(percentile_cont(0.5) within group (order by extract(epoch from touched - created_at) / 60)) from first_touch where touched is not null),
      'within_1h', (select count(*) from first_touch where touched is not null and touched - created_at <= interval '1 hour'),
      'touched', (select count(*) from first_touch where touched is not null),
      'leads', (select count(*) from ld)),
    'outcomes', coalesce((select jsonb_agg(jsonb_build_object('name', name, 'n', n) order by n desc) from outc), '[]'::jsonb),
    'invoices', jsonb_build_object(
      'count', (select count(*) from inv), 'total', coalesce((select sum(total_amount) from inv), 0), 'paid', coalesce((select sum(paid_amount) from inv), 0),
      'top', coalesce((select jsonb_agg(jsonb_build_object('name', name, 'total', total, 'paid', paid) order by total desc) from (
               select coalesce(client_name, 'Client') name, sum(total_amount) total, sum(paid_amount) paid from inv group by 1 order by 2 desc limit 5) t), '[]'::jsonb)),
    'meetings', jsonb_build_object(
      'booked', (select count(*) from mt), 'done', (select count(*) from mt where status = 'done'),
      'no_show', (select count(*) from mt where status = 'no_show'), 'cancelled', (select count(*) from mt where status = 'cancelled'),
      'upcoming', (select count(*) from mt where status = 'scheduled')),
    'bookings', jsonb_build_object(
      'count', (select count(*) from bk where status <> 'cancelled'), 'cancelled', (select count(*) from bk where status = 'cancelled'),
      'hours', coalesce((select round(sum(extract(epoch from (end_time - start_time)) / 3600)::numeric, 1) from bk where status <> 'cancelled' and end_time > start_time), 0),
      'value', coalesce((select sum(total_amount) from bk where status <> 'cancelled'), 0)),
    'orders', coalesce((select jsonb_object_agg(st, n) from (select st, count(*) n from ord group by 1) o), '{}'::jsonb)
  ) end
$$;
revoke all on function public.owner_business_focus(uuid, uuid, date, date) from public, anon;
grant execute on function public.owner_business_focus(uuid, uuid, date, date) to authenticated;

-- owner_dash_leads: p_step 'temp:<category>' = the leads of that category (applied in place with pg_get_functiondef + replace)
