-- Funnel → Facebook / Google Ads → Date / Campaign / Ad set / Ads Performance: the funnel's leads (lead date in the
-- range, India time) counted per day and per the ad they came from (leads.ad_campaign / ad_adset / ad_name).
-- Warm: temperature warm. Not Interested: temperature not_interested or a Lost stage. Closed: temperature closed or a
-- Won stage (as the Paid Podcast board). Funnels → view, as funnel_ads_report.
create or replace function public.funnel_ad_lead_counts(p_funnel uuid, p_from date, p_to date)
returns table(day date, campaign text, adset text, ad text, leads integer, warm integer, not_interested integer, closed integer)
language plpgsql stable security definer set search_path = '' as $$
declare f public.funnels;
begin
  select * into f from public.funnels where id = p_funnel;
  if f.id is null or not private.has_permission(f.tenant_id, 'funnels', 'view') then return; end if;
  return query
  select (l.created_at at time zone 'Asia/Kolkata')::date, l.ad_campaign, l.ad_adset, l.ad_name,
         count(*)::int,
         count(*) filter (where l.temperature = 'warm')::int,
         count(*) filter (where l.temperature = 'not_interested' or s.kind = 'lost')::int,
         count(*) filter (where l.temperature = 'closed' or s.kind = 'won')::int
    from public.leads l
    left join public.funnel_stages s on s.id = l.stage_id
   where l.funnel_id = f.id and not l.is_archived
     and l.created_at >= (p_from::timestamp at time zone 'Asia/Kolkata')
     and l.created_at < ((p_to + 1)::timestamp at time zone 'Asia/Kolkata')
   group by 1, 2, 3, 4;
end $$;
revoke all on function public.funnel_ad_lead_counts(uuid, date, date) from public, anon;
grant execute on function public.funnel_ad_lead_counts(uuid, date, date) to authenticated;
