-- Dashboard (owner): only what belongs to a business — Razorpay payments without a lead and ad spend on campaigns
-- not linked to a funnel are left out (no "Unassigned").
create or replace function public.owner_dashboard(p_tenant uuid, p_from date, p_to date, p_business uuid default null)
returns jsonb
language sql stable security definer set search_path = '' as $$
  with b as (
    select p_from f, p_to t, (p_from - (p_to - p_from + 1)) pf, (p_from - 1) pt,
           (p_from::timestamp at time zone 'Asia/Kolkata') d0, ((p_to + 1)::timestamp at time zone 'Asia/Kolkata') d1,
           ((p_from - (p_to - p_from + 1))::timestamp at time zone 'Asia/Kolkata') pd0,
           (now() at time zone 'Asia/Kolkata')::date today,
           '00000000-0000-0000-0000-000000000000'::uuid zero
     where private.is_owner_view(p_tenant)
  ),
  biz as (
    select x.id, x.name, x.type, x.sort_order from public.businesses x, b
     where x.tenant_id = p_tenant and x.is_active and x.archived_at is null and (p_business is null or x.id = p_business)
  ),
  -- money in: paid invoice parts + Razorpay not on an invoice
  rev as (
    select coalesce(i.business_id, b.zero) bid, ip.paid_on as day, ip.amount::numeric amt
      from public.invoice_payments ip join public.invoices i on i.id = ip.invoice_id, b
     where ip.tenant_id = p_tenant and ip.status = 'paid' and ip.paid_on between b.pf and b.t
    union all
    select coalesce(l.business_id, b.zero), (r.paid_at at time zone 'Asia/Kolkata')::date, (r.amount - coalesce(r.amount_refunded, 0))::numeric
      from public.razorpay_payments r left join public.leads l on l.id = r.lead_id, b
     where r.tenant_id = p_tenant and r.captured and r.invoice_id is null
       and r.paid_at >= b.pd0 and r.paid_at < b.d1
  ),
  -- ad spend (with GST)
  spend as (
    select coalesce(fn.business_id, b.zero) bid, mi.day, (mi.spend * (1 + coalesce(a.gst_rate, 18) / 100))::numeric amt, 'meta' platform, mi.campaign_id
      from public.meta_insights mi
      join public.meta_ad_accounts a on a.id = mi.account_id
      left join lateral (select l.funnel_id from public.funnel_ad_links l
                          where l.tenant_id = mi.tenant_id and l.campaign_id = mi.campaign_id and (l.adset_id is null or l.adset_id = mi.adset_id)
                          order by l.adset_id nulls last limit 1) lk on true
      left join public.funnels fn on fn.id = lk.funnel_id, b
     where mi.tenant_id = p_tenant and mi.day between b.pf and b.t
    union all
    select coalesce(fn.business_id, b.zero), gi.day, (gi.spend * (1 + coalesce(a.gst_rate, 18) / 100))::numeric, 'google', gi.campaign_id
      from public.google_insights gi
      join public.google_ad_accounts a on a.id = gi.account_id
      left join lateral (select l.funnel_id from public.funnel_google_links l where l.tenant_id = gi.tenant_id and l.campaign_id = gi.campaign_id limit 1) lk on true
      left join public.funnels fn on fn.id = lk.funnel_id, b
     where gi.tenant_id = p_tenant and gi.level = 'campaign' and gi.day between b.pf and b.t
  ),
  exp as (
    select coalesce(e.business_id, b.zero) bid, e.spent_on as day, e.amount::numeric amt, e.category
      from public.expenses e, b where e.tenant_id = p_tenant and e.spent_on between b.pf and b.t
  ),
  -- in the chosen business (or every business + unassigned)
  rev_s as (select * from rev where bid = coalesce(p_business, bid) and bid <> '00000000-0000-0000-0000-000000000000'),
  spend_s as (select * from spend where bid = coalesce(p_business, bid) and bid <> '00000000-0000-0000-0000-000000000000'),
  exp_s as (select * from exp where bid = coalesce(p_business, bid) and bid <> '00000000-0000-0000-0000-000000000000'),
  ld as (
    select l.id, coalesce(l.business_id, b.zero) bid, l.funnel_id, l.source_id, l.owner_id, l.temperature, s.kind stage_kind,
           (l.created_at at time zone 'Asia/Kolkata')::date as day, l.created_at >= b.d0 cur, l.ad_campaign
      from public.leads l left join public.funnel_stages s on s.id = l.stage_id, b
     where l.tenant_id = p_tenant and not coalesce(l.is_archived, false) and l.created_at >= b.pd0 and l.created_at < b.d1
       and (p_business is null or l.business_id = p_business)
  ),
  ldc as (
    select ld.*,
           (ld.temperature = 'closed' or ld.stage_kind = 'won') closed,
           (ld.temperature = 'not_interested' or ld.stage_kind = 'lost') lost,
           (exists (select 1 from public.follow_ups f where f.lead_id = ld.id and f.status = 'done')
             or exists (select 1 from public.calls c where c.lead_id = ld.id)) contacted,
           exists (select 1 from public.meetings m where m.lead_id = ld.id and m.status <> 'cancelled') met
      from ld where ld.cur
  ),
  pay_due as (
    select ip.amount::numeric amt, ip.due_on
      from public.invoice_payments ip join public.invoices i on i.id = ip.invoice_id
     where ip.tenant_id = p_tenant and ip.status = 'pending' and (p_business is null or i.business_id = p_business)
  ),
  kpi as (
    select
      coalesce((select sum(amt) from rev_s, b where day >= b.f), 0) revenue,
      coalesce((select sum(amt) from rev_s, b where day < b.f), 0) revenue_prev,
      coalesce((select sum(amt) from spend_s, b where day >= b.f), 0) ad_spend,
      coalesce((select sum(amt) from spend_s, b where day < b.f), 0) ad_spend_prev,
      coalesce((select sum(amt) from exp_s, b where day >= b.f), 0) expenses,
      coalesce((select sum(amt) from exp_s, b where day < b.f), 0) expenses_prev,
      (select count(*) from exp) expense_rows,
      (select count(*) from ld where cur) leads,
      (select count(*) from ld where not cur) leads_prev,
      (select count(*) from ldc where closed) closed,
      coalesce((select sum(amt) from pay_due), 0) due,
      coalesce((select sum(amt) from pay_due, b where due_on < b.today), 0) overdue,
      (select count(*) from pay_due, b where due_on < b.today) overdue_parts
  ),
  per_biz as (
    select x.id, x.name, x.type,
           coalesce((select sum(amt) from rev, b where rev.bid = x.id and day >= b.f), 0) revenue,
           coalesce((select sum(amt) from spend, b where spend.bid = x.id and day >= b.f), 0) ad_spend,
           coalesce((select sum(amt) from exp, b where exp.bid = x.id and day >= b.f), 0) expenses,
           (select count(*) from ldc where ldc.bid = x.id) leads,
           (select count(*) from ldc where ldc.bid = x.id and closed) closed,
           coalesce((select jsonb_agg(coalesce(w.r, 0) order by w.k) from (
              select g.k, (select sum(amt) from rev, b where rev.bid = x.id and day >= b.f and (day - b.f) / 7 = g.k) r
                from generate_series(0, ((select t - f from b) / 7)) g(k)) w), '[]'::jsonb) trend
      from biz x
  ),
  daily as (
    select d::date as day,
           coalesce((select sum(amt) from rev_s where rev_s.day = d::date), 0) revenue,
           coalesce((select sum(amt) from spend_s where spend_s.day = d::date), 0) spend,
           (select count(*) from ld where ld.cur and ld.day = d::date) leads
      from b, generate_series(b.f, b.t, interval '1 day') d
  ),
  fun as (
    select f.id, f.name, bz.name business,
           count(c.id) leads, count(c.id) filter (where c.contacted) contacted, count(c.id) filter (where c.met) met,
           count(c.id) filter (where c.closed) closed, count(c.id) filter (where c.lost) lost
      from public.funnels f join public.businesses bz on bz.id = f.business_id
      left join ldc c on c.funnel_id = f.id
     where f.tenant_id = p_tenant and f.archived_at is null and (p_business is null or f.business_id = p_business)
     group by f.id, f.name, bz.name
    having count(c.id) > 0
  ),
  src as (
    select coalesce(s.name, 'Unknown') name, count(*) n from ldc left join public.lead_sources s on s.id = ldc.source_id group by 1
  ),
  camp as (
    select sp.platform, sp.campaign_id, sum(sp.amt) spend,
           coalesce((select c.name from public.meta_campaigns c where c.tenant_id = p_tenant and c.campaign_id = sp.campaign_id and sp.platform = 'meta'),
                    (select c.name from public.google_campaigns c where c.tenant_id = p_tenant and c.campaign_id = sp.campaign_id and sp.platform = 'google'), sp.campaign_id) name
      from spend_s sp, b where sp.day >= b.f group by 1, 2
  ),
  camp2 as (
    select camp.*, (select count(*) from ld where ld.cur and ld.ad_campaign = camp.name) leads from camp order by spend desc limit 10
  ),
  mem as (
    select m.id, coalesce(p.full_name, p.email) name, r.name role
      from public.tenant_members m join public.profiles p on p.id = m.user_id left join public.roles r on r.id = m.role_id
     where m.tenant_id = p_tenant and m.status = 'active' and not coalesce(m.is_support, false)
  ),
  team as (
    select mem.id, mem.name, mem.role,
           (select count(*) from public.follow_ups f join public.leads l on l.id = f.lead_id, b
             where f.tenant_id = p_tenant and f.completed_by = mem.id and f.status = 'done' and f.completed_at >= b.d0 and f.completed_at < b.d1
               and (p_business is null or l.business_id = p_business)) fu_done,
           (select count(*) from public.follow_ups f join public.leads l on l.id = f.lead_id
             where f.tenant_id = p_tenant and f.assigned_to = mem.id and f.status = 'pending' and f.due_at < now()
               and (p_business is null or l.business_id = p_business)) overdue,
           (select count(*) from public.meetings m, b
             where m.tenant_id = p_tenant and m.assigned_to = mem.id and m.status = 'done' and m.meeting_date between b.f and b.t
               and (p_business is null or m.business_id = p_business)) meetings,
           (select count(*) from ldc where ldc.owner_id = mem.id) leads,
           (select count(*) from ldc where ldc.owner_id = mem.id and closed) closed
      from mem
  ),
  callers as (
    select t.emp_number, (array_agg(t.emp_name order by t.started_at desc) filter (where t.emp_name is not null))[1] name,
           count(*) calls, count(*) filter (where t.duration_sec > 0) connected, coalesce(sum(t.duration_sec), 0) talk_sec
      from public.callyzer_team_calls t, b
     where t.tenant_id = p_tenant and t.emp_number is not null and t.started_at >= b.d0 and t.started_at < b.d1
     group by t.emp_number
  ),
  attn as (
    select
      (select count(*) from public.follow_ups f join public.leads l on l.id = f.lead_id
        where f.tenant_id = p_tenant and f.status = 'pending' and f.due_at < now() and (p_business is null or l.business_id = p_business)) overdue_fu,
      (select count(*) from public.follow_ups f join public.leads l on l.id = f.lead_id, b
        where f.tenant_id = p_tenant and f.status = 'pending' and (f.due_at at time zone 'Asia/Kolkata')::date = b.today
          and (p_business is null or l.business_id = p_business)) due_today,
      (select count(*) from public.leads l left join public.funnel_stages s on s.id = l.stage_id
        where l.tenant_id = p_tenant and not coalesce(l.is_archived, false) and coalesce(s.kind, 'open') = 'open'
          and coalesce(l.temperature, '') not in ('not_interested', 'closed') and (p_business is null or l.business_id = p_business)
          and not exists (select 1 from public.follow_ups f where f.lead_id = l.id and f.status = 'done')
          and not exists (select 1 from public.calls c where c.lead_id = l.id)) first_call_pending,
      (select count(*) from public.leads l left join public.funnel_stages s on s.id = l.stage_id
        where l.tenant_id = p_tenant and not coalesce(l.is_archived, false) and coalesce(s.kind, 'open') = 'open'
          and coalesce(l.temperature, '') not in ('not_interested', 'closed') and (p_business is null or l.business_id = p_business)
          and not exists (select 1 from public.follow_ups f where f.lead_id = l.id and f.status = 'pending')) no_follow_up
  ),
  nx_meet as (
    select m.id, m.meeting_date, m.start_time, coalesce(nullif(trim(concat_ws(' ', l.first_name, l.last_name)), ''), m.title, 'Meeting') who,
           m.lead_id, (m.zoom_meeting_id is not null) zoom
      from public.meetings m left join public.leads l on l.id = m.lead_id, b
     where m.tenant_id = p_tenant and m.status = 'scheduled' and m.meeting_date >= b.today and (p_business is null or m.business_id = p_business)
     order by m.meeting_date, m.start_time limit 6
  ),
  nx_book as (
    select k.id, k.booking_date, k.start_time, k.client_name who, k.total_amount
      from public.bookings k, b
     where k.tenant_id = p_tenant and k.order_no is null and k.status = 'confirmed' and k.booking_date >= b.today
       and (p_business is null or k.business_id = p_business)
     order by k.booking_date, k.start_time limit 6
  ),
  nx_due as (
    select ip.id, ip.amount, ip.due_on, i.invoice_no, i.client_name who, i.id invoice_id
      from public.invoice_payments ip join public.invoices i on i.id = ip.invoice_id, b
     where ip.tenant_id = p_tenant and ip.status = 'pending' and ip.due_on <= b.today + 7 and (p_business is null or i.business_id = p_business)
     order by ip.due_on limit 6
  )
  select case when not exists (select 1 from b) then null else jsonb_build_object(
    'kpi', (select to_jsonb(kpi) from kpi),
    'businesses', coalesce((select jsonb_agg(to_jsonb(per_biz) order by per_biz.revenue desc, per_biz.leads desc) from per_biz), '[]'::jsonb),
    'daily', coalesce((select jsonb_agg(to_jsonb(daily) order by daily.day) from daily), '[]'::jsonb),
    'funnels', coalesce((select jsonb_agg(to_jsonb(fun) order by fun.leads desc) from fun), '[]'::jsonb),
    'sources', coalesce((select jsonb_agg(to_jsonb(src) order by src.n desc) from src), '[]'::jsonb),
    'campaigns', coalesce((select jsonb_agg(to_jsonb(camp2) order by camp2.spend desc) from camp2), '[]'::jsonb),
    'team', coalesce((select jsonb_agg(to_jsonb(team) order by team.fu_done desc, team.meetings desc, team.name) from team
                       where team.fu_done + team.overdue + team.meetings + team.leads > 0), '[]'::jsonb),
    'callers', coalesce((select jsonb_agg(to_jsonb(callers) order by callers.talk_sec desc) from callers), '[]'::jsonb),
    'attention', (select to_jsonb(attn) from attn),
    'next', jsonb_build_object(
      'meetings', coalesce((select jsonb_agg(to_jsonb(nx_meet) order by nx_meet.meeting_date, nx_meet.start_time) from nx_meet), '[]'::jsonb),
      'bookings', coalesce((select jsonb_agg(to_jsonb(nx_book) order by nx_book.booking_date, nx_book.start_time) from nx_book), '[]'::jsonb),
      'dues', coalesce((select jsonb_agg(to_jsonb(nx_due) order by nx_due.due_on) from nx_due), '[]'::jsonb))
  ) end
$$;
revoke all on function public.owner_dashboard(uuid, date, date, uuid) from public, anon;
grant execute on function public.owner_dashboard(uuid, date, date, uuid) to authenticated;
