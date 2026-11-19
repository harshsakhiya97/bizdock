-- Funnel → Overview (the funnel picture) for Overall / Facebook / Google. Facebook: the linked Facebook campaigns'
-- numbers and the leads whose UTM source is Facebook / Instagram; Google: the linked Google campaigns' numbers and the
-- leads whose UTM source is Google / YouTube; Overall: both ads and every lead. funnel_flow (Facebook, every lead) stays.
create or replace function public.funnel_flow_src(p_funnel uuid, p_from date, p_to date, p_source text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  f public.funnels;
  fb boolean := p_source in ('fb', 'all');
  gg boolean := p_source in ('google', 'all');
  res jsonb;
begin
  select * into f from public.funnels where id = p_funnel;
  if f.id is null or not private.has_permission(f.tenant_id, 'funnels', 'view') then return null; end if;

  with links as (
    select campaign_id, adset_id from public.funnel_ad_links where funnel_id = f.id and fb
  ), glinks as (
    select campaign_id from public.funnel_google_links where funnel_id = f.id and gg
  ), ins as (
    select i.spend, i.spend * (1 + a.gst_rate / 100) spend_gst, i.impressions, i.link_clicks, i.landing_page_views, i.leads, i.purchases
      from public.meta_insights i join public.meta_ad_accounts a on a.id = i.account_id
     where i.tenant_id = f.tenant_id and i.day between p_from and p_to
       and exists (select 1 from links l where l.campaign_id = i.campaign_id and (l.adset_id is null or l.adset_id = i.adset_id))
  ), gins as (
    select g.spend, g.spend * (1 + a.gst_rate / 100) spend_gst, g.impressions, g.clicks, g.conversions
      from public.google_insights g join public.google_ad_accounts a on a.id = g.account_id
     where g.tenant_id = f.tenant_id and g.level = 'campaign' and g.day between p_from and p_to
       and g.campaign_id in (select campaign_id from glinks)
  ), linked_names as (
    select lower(n.name) nm from public.meta_names n
     where n.tenant_id = f.tenant_id and n.level = 'campaign' and n.object_id in (select campaign_id from links)
    union
    select lower(c.name) from public.google_campaigns c where c.tenant_id = f.tenant_id and c.campaign_id in (select campaign_id from glinks) and c.name is not null
  ), lds as (
    select l.id, l.stage_id,
           exists (select 1 from linked_names x where x.nm = lower(btrim(l.utm_campaign))) as ads
      from public.leads l
     where l.funnel_id = f.id and not coalesce(l.is_archived, false)
       and (l.created_at at time zone 'Asia/Kolkata')::date between p_from and p_to
       and (p_source = 'all'
            or (p_source = 'fb' and lower(btrim(coalesce(l.utm_source, ''))) in ('fb', 'ig', 'facebook', 'instagram', 'meta', 'an', 'msg', 'messenger', 'threads', 'th'))
            or (p_source = 'google' and lower(btrim(coalesce(l.utm_source, ''))) in ('google', 'adwords', 'gads', 'googleads', 'google_ads', 'youtube', 'yt', 'gdn')))
  ), st as (
    select id, name, kind, sort_order from public.funnel_stages where funnel_id = f.id
  ), reach as (
    select lds.id, lds.ads,
           greatest(
             coalesce((select s.sort_order from st s where s.id = lds.stage_id and s.kind <> 'lost'), -1),
             coalesce((select max(s.sort_order) from public.lead_activities a join st s on s.id in (a.to_stage_id, a.from_stage_id)
                        where a.lead_id = lds.id and s.kind <> 'lost'), -1),
             0
           ) as far
      from lds
  ), money as (
    select b.lead_id, sum(b.total_amount) revenue, sum(coalesce(b.paid_amount, 0)) collected
      from public.bookings b join lds on lds.id = b.lead_id
     where b.status <> 'cancelled' group by b.lead_id
  )
  select jsonb_build_object(
    'source', p_source,
    'spend', coalesce((select sum(spend) from ins), 0) + coalesce((select sum(spend) from gins), 0),
    'spend_gst', coalesce((select sum(spend_gst) from ins), 0) + coalesce((select sum(spend_gst) from gins), 0),
    'impressions', coalesce((select sum(impressions) from ins), 0) + coalesce((select sum(impressions) from gins), 0),
    'link_clicks', coalesce((select sum(link_clicks) from ins), 0) + coalesce((select sum(clicks) from gins), 0),
    'lpv', coalesce((select sum(landing_page_views) from ins), 0),
    'meta_leads', coalesce((select sum(leads) from ins), 0),
    'purchases', coalesce((select sum(purchases) from ins), 0),
    'conversions', coalesce((select sum(conversions) from gins), 0),
    'leads', (select count(*) from lds),
    'leads_ads', (select count(*) from lds where ads),
    'stages', coalesce((select jsonb_agg(jsonb_build_object('name', s.name, 'kind', s.kind,
                 'n', (select count(*) from reach r where r.far >= s.sort_order),
                 'ads', (select count(*) from reach r where r.far >= s.sort_order and r.ads)) order by s.sort_order)
               from st s where s.kind <> 'lost'), '[]'::jsonb),
    'lost', (select count(*) from lds join st s on s.id = lds.stage_id where s.kind = 'lost'),
    'revenue', coalesce((select sum(revenue) from money), 0),
    'revenue_ads', coalesce((select sum(m.revenue) from money m join lds on lds.id = m.lead_id where lds.ads), 0),
    'collected', coalesce((select sum(collected) from money), 0),
    'linked', (select count(*) from links) + (select count(*) from glinks)
  ) into res;
  return res;
end $$;
revoke all on function public.funnel_flow_src(uuid, date, date, text) from public, anon;
grant execute on function public.funnel_flow_src(uuid, date, date, text) to authenticated;
