-- Course dashboard numbers in one call (rough first version). Runs as the caller, so the usual row access applies.
create or replace function public.course_dashboard(p_tenant uuid, p_business uuid default null, p_from date default null, p_to date default null)
returns jsonb
language sql stable security invoker
set search_path to ''
as $function$
with
f as (select coalesce(p_from, date '2000-01-01') as d1, coalesce(p_to, current_date) as d2),
l as (
  select l.id, l.created_at::date as d, l.owner_id, coalesce(nullif(l.extra->>'assigned_to', ''), '') as assigned
  from public.leads l where l.tenant_id = p_tenant and (p_business is null or l.business_id = p_business) and not l.is_archived
),
p as (
  select pu.* from public.purchases pu
  where pu.tenant_id = p_tenant and pu.status = 'active' and (p_business is null or pu.business_id = p_business)
),
pp as (
  select x.amount, x.paid_on, p.lead_id from public.purchase_payments x join p on p.id = x.purchase_id where x.status = 'paid'
),
e as (
  select x.amount, x.spent_on from public.expenses x where x.tenant_id = p_tenant and (p_business is null or x.business_id is null or x.business_id = p_business)
),
-- bought: a paid part, or a course recorded at ₹0 (imported sheets carry one total per person)
first_buy as (select lead_id, min(purchase_date) as d from p where paid_amount > 0 or total_amount = 0 group by lead_id),
months as (
  select generate_series(date_trunc('month', current_date) - interval '23 months', date_trunc('month', current_date), interval '1 month')::date as m
),
names as (
  select tm.id, pr.full_name from public.tenant_members tm join public.profiles pr on pr.id = tm.user_id where tm.tenant_id = p_tenant
),
who as (
  select l.id as lead_id, l.d, coalesce(n.full_name, nullif(l.assigned, ''), 'Unassigned') as name
  from l left join names n on n.id = l.owner_id
),
t_leads as (
  select w.name, count(*) filter (where w.d between f.d1 and f.d2) as leads, count(b.lead_id) filter (where b.d between f.d1 and f.d2) as converted
  from who w left join first_buy b on b.lead_id = w.lead_id cross join f group by w.name
),
t_coll as (select w.name, sum(pp.amount) as collected from pp join who w on w.lead_id = pp.lead_id cross join f where pp.paid_on between f.d1 and f.d2 group by w.name),
t_out as (select w.name, sum(greatest(p.total_amount - p.paid_amount, 0)) as outstanding from p join who w on w.lead_id = p.lead_id where p.refund_amount = 0 group by w.name)
select jsonb_build_object(
  'leads', (select count(*) from l, f where l.d between f.d1 and f.d2),
  'converted', (select count(*) from first_buy b, f where b.d between f.d1 and f.d2),
  'sold', (select coalesce(sum(total_amount), 0) from p, f where p.purchase_date between f.d1 and f.d2),
  'enrollments', (select count(*) from p, f where p.purchase_date between f.d1 and f.d2),
  'collected', (select coalesce(sum(amount), 0) from pp, f where pp.paid_on between f.d1 and f.d2),
  'pending_all', (select coalesce(sum(greatest(total_amount - paid_amount, 0)), 0) from p where refund_amount = 0),
  'refunded', (select coalesce(sum(refund_amount), 0) from p, f where p.refund_amount > 0 and coalesce(p.refunded_on, p.purchase_date) between f.d1 and f.d2),
  'expenses', (select coalesce(sum(amount), 0) from e, f where e.spent_on between f.d1 and f.d2),
  'months', (select jsonb_agg(jsonb_build_object(
      'm', to_char(mo.m, 'YYYY-MM'),
      'collected', (select coalesce(sum(amount), 0) from pp where date_trunc('month', pp.paid_on) = mo.m),
      'sold', (select coalesce(sum(total_amount), 0) from p where date_trunc('month', p.purchase_date) = mo.m),
      'leads', (select count(*) from l where date_trunc('month', l.d) = mo.m),
      'converted', (select count(*) from first_buy b where date_trunc('month', b.d) = mo.m),
      'expenses', (select coalesce(sum(amount), 0) from e where date_trunc('month', e.spent_on) = mo.m)
    ) order by mo.m) from months mo),
  'courses', (select coalesce(jsonb_agg(c order by c->>'order', c->>'name'), '[]') from (
      select jsonb_build_object(
        'name', coalesce(pr.name, p.name),
        'order', lpad(coalesce(pr.sort_order, 999)::text, 4, '0'),
        'enrollments', count(*),
        'sold', coalesce(sum(p.total_amount), 0),
        'collected', coalesce(sum(p.paid_amount), 0)
      ) as c
      from p left join public.products pr on pr.id = p.product_id cross join f
      where p.purchase_date between f.d1 and f.d2
      group by coalesce(pr.name, p.name), pr.sort_order) s),
  'team', (select coalesce(jsonb_agg(jsonb_build_object(
        'name', t.name, 'leads', t.leads, 'converted', t.converted,
        'collected', coalesce(c.collected, 0), 'outstanding', coalesce(o.outstanding, 0)
      ) order by coalesce(c.collected, 0) desc, t.leads desc), '[]')
      from t_leads t left join t_coll c on c.name = t.name left join t_out o on o.name = t.name)
)
$function$;
grant execute on function public.course_dashboard(uuid, uuid, date, date) to authenticated;
