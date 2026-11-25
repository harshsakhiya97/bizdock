-- Funnel → Overview → Scorecard: the records behind the Marketing numbers (same rules as funnel_flow_src):
--   ads:   each Facebook ad / Google campaign of the funnel in the period — spend, impressions, clicks, LP views
--   leads: the period's leads of the funnel (the source picked), each with ads = its UTM campaign is a linked campaign
create or replace function public.funnel_flow_detail(p_funnel uuid, p_from date, p_to date, p_source text)
returns jsonb
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
    select i.campaign_id, i.adset_id, i.ad_id, sum(i.spend) spend, sum(i.spend * (1 + a.gst_rate / 100)) spend_gst,
           sum(i.impressions) impressions, sum(i.link_clicks) link_clicks, sum(i.landing_page_views) lpv
      from public.meta_insights i join public.meta_ad_accounts a on a.id = i.account_id
     where i.tenant_id = f.tenant_id and i.day between p_from and p_to
       and exists (select 1 from links l where l.campaign_id = i.campaign_id and (l.adset_id is null or l.adset_id = i.adset_id))
     group by 1, 2, 3
  ), gins as (
    select g.campaign_id, sum(g.spend) spend, sum(g.spend * (1 + a.gst_rate / 100)) spend_gst, sum(g.impressions) impressions, sum(g.clicks) clicks
      from public.google_insights g join public.google_ad_accounts a on a.id = g.account_id
     where g.tenant_id = f.tenant_id and g.level = 'campaign' and g.day between p_from and p_to
       and g.campaign_id in (select campaign_id from glinks)
     group by 1
  ), linked_names as (
    select lower(n.name) nm from public.meta_names n
     where n.tenant_id = f.tenant_id and n.level = 'campaign' and n.object_id in (select campaign_id from links)
    union
    select lower(c.name) from public.google_campaigns c where c.tenant_id = f.tenant_id and c.campaign_id in (select campaign_id from glinks) and c.name is not null
  ), lds as (
    select l.id, exists (select 1 from linked_names x where x.nm = lower(btrim(l.utm_campaign))) as ads
      from public.leads l
     where l.funnel_id = f.id and not coalesce(l.is_archived, false)
       and (l.created_at at time zone 'Asia/Kolkata')::date between p_from and p_to
       and (p_source = 'all'
            or (p_source = 'fb' and lower(btrim(coalesce(l.utm_source, ''))) in ('fb', 'ig', 'facebook', 'instagram', 'meta', 'an', 'msg', 'messenger', 'threads', 'th'))
            or (p_source = 'google' and lower(btrim(coalesce(l.utm_source, ''))) in ('google', 'adwords', 'gads', 'googleads', 'google_ads', 'youtube', 'yt', 'gdn')))
  )
  select jsonb_build_object(
    'ads', coalesce((
      select jsonb_agg(x order by (x->>'spend')::numeric desc) from (
        select jsonb_build_object('key', 'fb-' || i.ad_id, 'platform', 'Facebook',
                 'campaign', (select n.name from public.meta_names n where n.tenant_id = f.tenant_id and n.level = 'campaign' and n.object_id = i.campaign_id limit 1),
                 'group', (select n.name from public.meta_names n where n.tenant_id = f.tenant_id and n.level = 'adset' and n.object_id = i.adset_id limit 1),
                 'ad', (select n.name from public.meta_names n where n.tenant_id = f.tenant_id and n.level = 'ad' and n.object_id = i.ad_id limit 1),
                 'spend', i.spend, 'spend_gst', i.spend_gst, 'impressions', i.impressions, 'clicks', i.link_clicks, 'lpv', i.lpv) x
          from ins i
        union all
        select jsonb_build_object('key', 'g-' || g.campaign_id, 'platform', 'Google',
                 'campaign', (select c.name from public.google_campaigns c where c.tenant_id = f.tenant_id and c.campaign_id = g.campaign_id limit 1),
                 'group', null, 'ad', null,
                 'spend', g.spend, 'spend_gst', g.spend_gst, 'impressions', g.impressions, 'clicks', g.clicks, 'lpv', null)
          from gins g
      ) t), '[]'::jsonb),
    'leads', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'ads', ads)) from lds), '[]'::jsonb)
  ) into res;
  return res;
end $$;
revoke all on function public.funnel_flow_detail(uuid, date, date, text) from public, anon;
grant execute on function public.funnel_flow_detail(uuid, date, date, text) to authenticated;
