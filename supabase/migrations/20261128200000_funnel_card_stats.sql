-- Funnels list: per funnel, the running daily ad budget (Facebook + Google), today's spend and leads, and the last 30 days
-- (ending yesterday, as Ads Manager counts it). Spend without GST. Runs as the caller, so RLS decides what is counted.
create or replace function public.funnel_card_stats(p_tenant uuid)
 returns jsonb
 language sql
 stable
 security invoker
 set search_path to ''
as $function$
  with d as (select (now() at time zone 'Asia/Kolkata')::date as today),
  ml as (select funnel_id, campaign_id, adset_id from public.funnel_ad_links where tenant_id = p_tenant),
  gl as (select funnel_id, campaign_id from public.funnel_google_links where tenant_id = p_tenant),
  -- Facebook budget: an active campaign's own budget (CBO), else its active ad sets' (ABO)
  mb as (
    select ml.funnel_id,
           case when ml.adset_id is null and c.daily_budget is not null then c.daily_budget
                else (select coalesce(sum(s.daily_budget), 0) from public.meta_adsets s
                       where s.tenant_id = p_tenant and s.campaign_id = ml.campaign_id and s.effective_status = 'ACTIVE'
                         and (ml.adset_id is null or s.adset_id = ml.adset_id)) end as b
      from ml join public.meta_campaigns c on c.tenant_id = p_tenant and c.campaign_id = ml.campaign_id
     where c.effective_status = 'ACTIVE'
  ),
  gb as (
    select gl.funnel_id, c.daily_budget as b
      from gl join public.google_campaigns c on c.tenant_id = p_tenant and c.campaign_id = gl.campaign_id
     where c.status = 'ENABLED'
  ),
  ms as (
    select ml.funnel_id, i.day, sum(i.spend) as s
      from ml join public.meta_insights i on i.tenant_id = p_tenant and i.campaign_id = ml.campaign_id and (ml.adset_id is null or i.adset_id = ml.adset_id), d
     where i.day between d.today - 30 and d.today
     group by 1, 2
  ),
  gs as (
    select gl.funnel_id, i.day, sum(i.spend) as s
      from gl join public.google_insights i on i.tenant_id = p_tenant and i.level = 'campaign' and i.campaign_id = gl.campaign_id, d
     where i.day between d.today - 30 and d.today
     group by 1, 2
  ),
  sp as (select funnel_id, day, sum(s) as s from (select * from ms union all select * from gs) x group by 1, 2),
  ld as (
    select l.funnel_id, (l.created_at at time zone 'Asia/Kolkata')::date as day, count(*) as n
      from public.leads l, d
     where l.tenant_id = p_tenant and l.funnel_id is not null and not l.is_archived
       and l.created_at >= ((d.today - 30)::timestamp at time zone 'Asia/Kolkata')
     group by 1, 2
  ),
  f as (select id from public.funnels where tenant_id = p_tenant)
  select coalesce(jsonb_object_agg(f.id, jsonb_build_object(
    'budget', (select coalesce(sum(b), 0) from mb where mb.funnel_id = f.id) + (select coalesce(sum(b), 0) from gb where gb.funnel_id = f.id),
    'has_ads', exists (select 1 from ml where ml.funnel_id = f.id) or exists (select 1 from gl where gl.funnel_id = f.id),
    'spend_today', (select coalesce(sum(s), 0) from sp, d where sp.funnel_id = f.id and sp.day = d.today),
    'leads_today', (select coalesce(sum(n), 0) from ld, d where ld.funnel_id = f.id and ld.day = d.today),
    'spend_30', (select coalesce(sum(s), 0) from sp, d where sp.funnel_id = f.id and sp.day between d.today - 30 and d.today - 1),
    'leads_30', (select coalesce(sum(n), 0) from ld, d where ld.funnel_id = f.id and ld.day between d.today - 30 and d.today - 1)
  )), '{}'::jsonb)
  from f;
$function$;
grant execute on function public.funnel_card_stats(uuid) to authenticated;
