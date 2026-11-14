-- The funnel's flow for the Overview (like a 3D funnel report): Facebook's impressions → link clicks → landing page
-- views → this funnel's leads → each stage reached → won → revenue, with ads vs organic. A lead is "ads" when its form
-- sent a campaign name of a campaign linked to this funnel. A stage is "reached" when the lead is at it or a later
-- open / won stage now, or ever moved into or out of it (lead_activities), so Lost leads count up to where they got.
create or replace function public.funnel_flow(p_funnel uuid, p_from date, p_to date) returns jsonb
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
    select i.* from public.meta_insights i
     where i.tenant_id = f.tenant_id and i.day between p_from and p_to
       and exists (select 1 from links l where l.campaign_id = i.campaign_id and (l.adset_id is null or l.adset_id = i.adset_id))
  ), linked_names as (
    select lower(n.name) nm from public.meta_names n
     where n.tenant_id = f.tenant_id and n.level = 'campaign' and n.object_id in (select campaign_id from links)
  ), lds as (
    select l.id, l.stage_id,
           exists (select 1 from linked_names x where x.nm = lower(btrim(l.utm_campaign))) as ads
      from public.leads l
     where l.funnel_id = f.id and not coalesce(l.is_archived, false)
       and (l.created_at at time zone 'Asia/Kolkata')::date between p_from and p_to
  ), st as (
    select id, name, kind, sort_order from public.funnel_stages where funnel_id = f.id
  ), reach as (
    -- the furthest open / won stage each lead got to
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
    'spend', coalesce((select sum(spend) from ins), 0),
    'impressions', coalesce((select sum(impressions) from ins), 0),
    'link_clicks', coalesce((select sum(link_clicks) from ins), 0),
    'lpv', coalesce((select sum(landing_page_views) from ins), 0),
    'meta_leads', coalesce((select sum(leads) from ins), 0),
    'purchases', coalesce((select sum(purchases) from ins), 0),
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
    'linked', (select count(*) from links)
  ) into res;
  return res;
end $$;
revoke all on function public.funnel_flow(uuid, date, date) from public, anon;
grant execute on function public.funnel_flow(uuid, date, date) to authenticated;
