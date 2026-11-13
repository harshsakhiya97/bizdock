-- A funnel's ads report for a date range (India time): spend with GST (Meta's numbers of the campaigns / ad sets linked to
-- the funnel; days without Meta numbers fall back to the funnel's ad_spend rows), its leads and where they are, revenue
-- (booking totals with GST), collected and balance; per day and per campaign / ad set / ad (leads matched by the names
-- their form sent, any name the campaign / ad set / ad has had).
create or replace function public.funnel_ads_report(p_funnel uuid, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  f public.funnels;
  res jsonb;
begin
  select * into f from public.funnels where id = p_funnel;
  if f.id is null or not private.has_permission(f.tenant_id, 'funnels', 'view') then return null; end if;

  with links as (
    select campaign_id, adset_id from public.funnel_ad_links where funnel_id = f.id
  ), ins as (
    select i.*, a.gst_rate from public.meta_insights i join public.meta_ad_accounts a on a.id = i.account_id
     where i.tenant_id = f.tenant_id and i.day between p_from and p_to
       and exists (select 1 from links l where l.campaign_id = i.campaign_id and (l.adset_id is null or l.adset_id = i.adset_id))
  ), meta_days as (
    select day, sum(spend) spend, sum(spend * (1 + gst_rate / 100)) spend_gst from ins group by day
  ), old_days as (
    -- the funnel's own day-wise spend (old CRM / typed in) on days Meta has nothing for
    select s.spend_date as day, s.amount spend, s.amount * 1.18 spend_gst from public.ad_spend s
     where s.funnel_id = f.id and s.spend_date between p_from and p_to and not exists (select 1 from meta_days m where m.day = s.spend_date)
  ), days as (
    select day, spend, spend_gst, true as meta from meta_days union all select day, spend, spend_gst, false from old_days
  ), lds as (
    select l.id, l.stage_id, l.utm_campaign, l.utm_term, l.utm_content, (l.created_at at time zone 'Asia/Kolkata')::date as day
      from public.leads l
     where l.funnel_id = f.id and not coalesce(l.is_archived, false)
       and (l.created_at at time zone 'Asia/Kolkata')::date between p_from and p_to
  ), money as (
    select b.lead_id, sum(b.total_amount) revenue, sum(coalesce(b.paid_amount, 0)) collected
      from public.bookings b join lds on lds.id = b.lead_id
     where b.status <> 'cancelled' group by b.lead_id
  ), stage_counts as (
    select s.id, s.name, s.kind, s.sort_order, count(lds.id) n
      from public.funnel_stages s left join lds on lds.stage_id = s.id
     where s.funnel_id = f.id group by s.id order by s.sort_order
  ), lead_ad as (
    -- each lead's campaign / ad set / ad (by the names its form sent)
    select lds.id, lds.stage_id,
           (select n.object_id from public.meta_names n where n.tenant_id = f.tenant_id and n.level = 'campaign' and lower(n.name) = lower(btrim(lds.utm_campaign)) limit 1) as campaign_id,
           (select n.object_id from public.meta_names n where n.tenant_id = f.tenant_id and n.level = 'adset' and lower(n.name) = lower(btrim(lds.utm_term)) limit 1) as adset_id,
           (select n.object_id from public.meta_names n where n.tenant_id = f.tenant_id and n.level = 'ad' and lower(n.name) = lower(btrim(lds.utm_content)) limit 1) as ad_id
      from lds
  ), by_ad as (
    select i.campaign_id, i.adset_id, i.ad_id, sum(i.spend) spend, sum(i.spend * (1 + i.gst_rate / 100)) spend_gst,
           sum(i.impressions) impressions, sum(i.clicks) clicks, sum(i.link_clicks) link_clicks, sum(i.landing_page_views) lpv, sum(i.leads) meta_leads
      from ins i group by 1, 2, 3
  ), ad_rows as (
    select b.*, c.name campaign_name, s.name adset_name, d.name ad_name, d.effective_status,
           (select count(*) from lead_ad la where la.ad_id = b.ad_id) leads,
           (select count(*) from lead_ad la join public.funnel_stages st on st.id = la.stage_id where la.ad_id = b.ad_id and st.kind = 'won') won,
           (select coalesce(sum(m.revenue), 0) from lead_ad la join money m on m.lead_id = la.id where la.ad_id = b.ad_id) revenue
      from by_ad b
      left join public.meta_campaigns c on c.tenant_id = f.tenant_id and c.campaign_id = b.campaign_id
      left join public.meta_adsets s on s.tenant_id = f.tenant_id and s.adset_id = b.adset_id
      left join public.meta_ads d on d.tenant_id = f.tenant_id and d.ad_id = b.ad_id
  )
  select jsonb_build_object(
    'spend', coalesce((select sum(spend) from days), 0),
    'spend_gst', coalesce((select sum(spend_gst) from days), 0),
    'old_days', (select count(*) from old_days),
    'impressions', coalesce((select sum(impressions) from ins), 0),
    'clicks', coalesce((select sum(link_clicks) from ins), 0),
    'meta_leads', coalesce((select sum(leads) from ins), 0),
    'leads', (select count(*) from lds),
    'won', (select count(*) from lds join public.funnel_stages s on s.id = lds.stage_id where s.kind = 'won'),
    'lost', (select count(*) from lds join public.funnel_stages s on s.id = lds.stage_id where s.kind = 'lost'),
    'revenue', coalesce((select sum(revenue) from money), 0),
    'collected', coalesce((select sum(collected) from money), 0),
    'stages', coalesce((select jsonb_agg(jsonb_build_object('name', name, 'kind', kind, 'n', n) order by sort_order) from stage_counts), '[]'::jsonb),
    'days', coalesce((select jsonb_agg(jsonb_build_object('day', d.day, 'spend', d.spend, 'spend_gst', d.spend_gst, 'meta', d.meta,
                       'leads', (select count(*) from lds where lds.day = d.day)) order by d.day) from days d), '[]'::jsonb),
    'ads', coalesce((select jsonb_agg(to_jsonb(r) order by r.spend desc) from ad_rows r), '[]'::jsonb),
    'linked', (select count(*) from links)
  ) into res;
  return res;
end $$;
revoke all on function public.funnel_ads_report(uuid, date, date) from public, anon;
grant execute on function public.funnel_ads_report(uuid, date, date) to authenticated;
