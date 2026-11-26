-- Funnel tabs "Facebook Ads N" / "Google Ads N": only the linked campaigns whose name matches one of the funnel's tags
-- (same as the tab's list). Runs as the caller (their read rules apply).
create or replace function public.funnel_campaign_counts(p_funnel uuid) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'meta', (select count(distinct l.campaign_id) from public.funnel_ad_links l
               join public.funnels f on f.id = l.funnel_id
               join public.meta_campaigns c on c.tenant_id = l.tenant_id and c.campaign_id = l.campaign_id
              where l.funnel_id = p_funnel and private.tag_hit(c.name, f.meta_tags) is not null),
    'google', (select count(distinct l.campaign_id) from public.funnel_google_links l
               join public.funnels f on f.id = l.funnel_id
               join public.google_campaigns c on c.tenant_id = l.tenant_id and c.campaign_id = l.campaign_id
              where l.funnel_id = p_funnel and private.tag_hit(c.name, f.google_tags) is not null))
$$;
grant execute on function public.funnel_campaign_counts(uuid) to authenticated;
