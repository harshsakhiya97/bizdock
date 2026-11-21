-- course_dashboard, faster: access is checked once (member of the workspace, and the business when one is picked)
-- instead of on every row, and the months are added up in one pass. Counts a course recorded at ₹0 as bought.
create or replace function public.course_dashboard(p_tenant uuid, p_business uuid default null, p_from date default null, p_to date default null)
returns jsonb
language plpgsql stable security definer
set search_path to ''
set statement_timeout to '30s'
as $function$
declare
  d1 date := coalesce(p_from, date '2000-01-01');
  d2 date := coalesce(p_to, current_date);
  m0 date := (date_trunc('month', current_date) - interval '23 months')::date;
  ok_biz uuid[];
  res jsonb;
begin
  if not (private.is_member(p_tenant) or private.is_platform_owner()) then raise exception 'Not allowed'; end if;
  select coalesce(array_agg(b.id), '{}') into ok_biz from public.businesses b
   where b.tenant_id = p_tenant and (p_business is null or b.id = p_business) and private.can_access_business(b.id);

  with
  l as (
    select l.id, l.created_at::date as d, l.owner_id, coalesce(nullif(l.extra->>'assigned_to', ''), '') as assigned
    from public.leads l where l.tenant_id = p_tenant and l.business_id = any(ok_biz) and not l.is_archived
  ),
  p as (
    select pu.id, pu.lead_id, pu.product_id, pu.name, pu.total_amount, pu.paid_amount, pu.refund_amount, pu.refunded_on, pu.purchase_date
    from public.purchases pu where pu.tenant_id = p_tenant and pu.status = 'active' and pu.business_id = any(ok_biz)
  ),
  pp as (select x.amount, x.paid_on, p.lead_id from public.purchase_payments x join p on p.id = x.purchase_id where x.status = 'paid'),
  e as (select x.amount, x.spent_on from public.expenses x where x.tenant_id = p_tenant and (x.business_id is null or x.business_id = any(ok_biz))),
  fb as (select lead_id, min(purchase_date) as d from p where paid_amount > 0 or total_amount = 0 group by lead_id),
  months as (select generate_series(m0, date_trunc('month', current_date)::date, interval '1 month')::date as m),
  mc as (select date_trunc('month', paid_on)::date m, sum(amount) v from pp where paid_on >= m0 group by 1),
  ms as (select date_trunc('month', purchase_date)::date m, sum(total_amount) v from p where purchase_date >= m0 group by 1),
  ml as (select date_trunc('month', d)::date m, count(*) v from l where d >= m0 group by 1),
  mv as (select date_trunc('month', d)::date m, count(*) v from fb where d >= m0 group by 1),
  me as (select date_trunc('month', spent_on)::date m, sum(amount) v from e where spent_on >= m0 group by 1),
  names as (select tm.id, pr.full_name from public.tenant_members tm join public.profiles pr on pr.id = tm.user_id where tm.tenant_id = p_tenant),
  who as (select l.id as lead_id, l.d, coalesce(n.full_name, nullif(l.assigned, ''), 'Unassigned') as name from l left join names n on n.id = l.owner_id),
  t_leads as (
    select w.name, count(*) filter (where w.d between d1 and d2) as leads, count(b.lead_id) filter (where b.d between d1 and d2) as converted
    from who w left join fb b on b.lead_id = w.lead_id group by w.name
  ),
  t_coll as (select w.name, sum(pp.amount) as collected from pp join who w on w.lead_id = pp.lead_id where pp.paid_on between d1 and d2 group by w.name),
  t_out as (select w.name, sum(greatest(p.total_amount - p.paid_amount, 0)) as outstanding from p join who w on w.lead_id = p.lead_id where p.refund_amount = 0 group by w.name)
  select jsonb_build_object(
    'leads', (select count(*) from l where d between d1 and d2),
    'converted', (select count(*) from fb where d between d1 and d2),
    'sold', (select coalesce(sum(total_amount), 0) from p where purchase_date between d1 and d2),
    'enrollments', (select count(*) from p where purchase_date between d1 and d2),
    'collected', (select coalesce(sum(amount), 0) from pp where paid_on between d1 and d2),
    'pending_all', (select coalesce(sum(greatest(total_amount - paid_amount, 0)), 0) from p where refund_amount = 0),
    'refunded', (select coalesce(sum(refund_amount), 0) from p where refund_amount > 0 and coalesce(refunded_on, purchase_date) between d1 and d2),
    'expenses', (select coalesce(sum(amount), 0) from e where spent_on between d1 and d2),
    'months', (select jsonb_agg(jsonb_build_object(
        'm', to_char(mo.m, 'YYYY-MM'),
        'collected', coalesce(mc.v, 0), 'sold', coalesce(ms.v, 0), 'leads', coalesce(ml.v, 0), 'converted', coalesce(mv.v, 0), 'expenses', coalesce(me.v, 0)
      ) order by mo.m)
      from months mo left join mc on mc.m = mo.m left join ms on ms.m = mo.m left join ml on ml.m = mo.m left join mv on mv.m = mo.m left join me on me.m = mo.m),
    'courses', (select coalesce(jsonb_agg(c order by c->>'order', c->>'name'), '[]') from (
        select jsonb_build_object(
          'name', coalesce(pr.name, p.name), 'order', lpad(coalesce(pr.sort_order, 999)::text, 4, '0'),
          'enrollments', count(*), 'sold', coalesce(sum(p.total_amount), 0), 'collected', coalesce(sum(p.paid_amount), 0)
        ) as c
        from p left join public.products pr on pr.id = p.product_id
        where p.purchase_date between d1 and d2
        group by coalesce(pr.name, p.name), pr.sort_order) s),
    'team', (select coalesce(jsonb_agg(jsonb_build_object(
          'name', t.name, 'leads', t.leads, 'converted', t.converted,
          'collected', coalesce(c.collected, 0), 'outstanding', coalesce(o.outstanding, 0)
        ) order by coalesce(c.collected, 0) desc, t.leads desc), '[]')
        from t_leads t left join t_coll c on c.name = t.name left join t_out o on o.name = t.name)
  ) into res;
  return res;
end
$function$;
grant execute on function public.course_dashboard(uuid, uuid, date, date) to authenticated;
