-- Ad set name: utm_term as text (some pages send the ad set's name there, utm_medium = "paid_social") is used before
-- utm_medium; a name that is an ad set of the workspace wins; generic mediums (paid_social, cpc, …) are not names.
-- Every lead's ad fields filled again (Source untouched).
-- funnel_ad_leads: the funnel's leads (lead date in the range) one per row, for the Ads insights (numbers open the leads).
create or replace function private.lead_ad_fill(l public.leads, p_source boolean) returns public.leads
language plpgsql security definer set search_path = '' as $$
declare
  pu text := coalesce(l.extra ->> 'page_url', '');
  ru text := coalesce(l.extra ->> 'redirect_url', '');
  cid text;
  sid text;
  aid text;
  v text;
  code text;
  num text := '^\d{6,}$';
  generic text := '^(paid_social|paidsocial|paid|social|cpc|cpm|ppc|display|email|organic|referral|banner|video|story|stories|feed|reels?|none|\(none\)|\{\{.*\}\})$';
  t_term text := case when coalesce(l.utm_term, '') !~ num then nullif(trim(l.utm_term), '') end;
  t_med text := nullif(trim(l.utm_medium), '');
begin
  cid := coalesce(nullif(l.extra ->> 'utm_id', ''), nullif(l.extra ->> 'campaign_id', ''), private.url_param(pu, 'utm_id'), private.url_param(ru, 'utm_id'),
                  private.url_param(pu, 'campaign_id'), private.url_param(pu, 'gad_campaignid'),
                  case when l.utm_campaign ~ num then l.utm_campaign end);
  sid := coalesce(nullif(l.extra ->> 'adset_id', ''), case when l.utm_term ~ num then l.utm_term end,
                  case when private.url_param(pu, 'utm_term') ~ num then private.url_param(pu, 'utm_term') end,
                  private.url_param(pu, 'adset_id'), private.url_param(pu, 'adgroupid'));
  aid := coalesce(nullif(l.extra ->> 'ad_id', ''), nullif(l.extra ->> 'h_ad_id', ''), private.url_param(pu, 'h_ad_id'), private.url_param(pu, 'ad_id'),
                  private.url_param(ru, 'h_ad_id'), case when l.utm_content ~ num then l.utm_content end);
  l.fbclid := coalesce(nullif(l.extra ->> 'fbclid', ''), private.url_param(pu, 'fbclid'), private.url_param(ru, 'fbclid'));
  l.gclid := coalesce(nullif(l.extra ->> 'gclid', ''), private.url_param(pu, 'gclid'), private.url_param(ru, 'gclid'));

  v := null;
  if cid is not null then
    select c.name into v from public.meta_campaigns c where c.tenant_id = l.tenant_id and c.campaign_id = cid;
    if v is null then select c.name into v from public.google_campaigns c where c.tenant_id = l.tenant_id and c.campaign_id = cid; end if;
  end if;
  l.ad_campaign := coalesce(v, case when l.utm_campaign !~ num then nullif(trim(l.utm_campaign), '') end);

  v := null;
  if sid is not null then
    select s.name into v from public.meta_adsets s where s.tenant_id = l.tenant_id and s.adset_id = sid;
    if v is null then select g.name into v from public.google_ad_groups g where g.tenant_id = l.tenant_id and g.ad_group_id = sid; end if;
  end if;
  -- a text utm_term / utm_medium that is one of the workspace's ad set names
  if v is null then
    select s.name into v from public.meta_adsets s where s.tenant_id = l.tenant_id and lower(s.name) in (lower(coalesce(t_term, '')), lower(coalesce(t_med, ''))) limit 1;
  end if;
  if v is null then
    select g.name into v from public.google_ad_groups g where g.tenant_id = l.tenant_id and lower(g.name) in (lower(coalesce(t_term, '')), lower(coalesce(t_med, ''))) limit 1;
  end if;
  l.ad_adset := coalesce(v, t_term, case when t_med !~ num and lower(t_med) !~ generic then t_med end);

  v := null;
  if aid is not null then
    select a.name into v from public.meta_ads a where a.tenant_id = l.tenant_id and a.ad_id = aid;
    if v is null then select a.name into v from public.google_ads a where a.tenant_id = l.tenant_id and a.ad_id = aid; end if;
  end if;
  l.ad_name := coalesce(v, case when l.utm_content !~ num then nullif(trim(l.utm_content), '') end);

  if l.sheet_id is not null and l.ad_campaign is null and l.ad_adset is null and l.ad_name is null and coalesce(l.utm_source, '') = '' then
    select s.name into l.ad_campaign from public.funnel_sheets s where s.id = l.sheet_id;
  end if;

  if p_source then
    code := coalesce(nullif(trim(l.utm_source), ''), private.url_param(pu, 'utm_source'));
    if code is not null and code not like '%{{%' then
      v := private.source_for_code(l.tenant_id, code);
      if v is not null then
        l.source_id := private.source_id_named(l.tenant_id, v);
        l.utm_source_pending := null;
      else
        l.utm_source_pending := lower(trim(code));
      end if;
    elsif l.sheet_id is not null then
      l.source_id := private.source_id_named(l.tenant_id, 'Google Sheet');
      l.utm_source_pending := null;
    end if;
  end if;
  return l;
end $$;

alter table public.leads disable trigger lead_insight_touch;
alter table public.leads disable trigger leads_set_updated_at;
alter table public.leads disable trigger leads_ad_info;
update public.leads l set ad_campaign = x.ad_campaign, ad_adset = x.ad_adset, ad_name = x.ad_name, fbclid = x.fbclid, gclid = x.gclid
from (select f.* from public.leads l2 cross join lateral private.lead_ad_fill(l2, false) f) x
where x.id = l.id
  and (l.ad_campaign is distinct from x.ad_campaign or l.ad_adset is distinct from x.ad_adset or l.ad_name is distinct from x.ad_name
       or l.fbclid is distinct from x.fbclid or l.gclid is distinct from x.gclid);
alter table public.leads enable trigger leads_ad_info;
alter table public.leads enable trigger leads_set_updated_at;
alter table public.leads enable trigger lead_insight_touch;

create or replace function public.funnel_ad_leads(p_funnel uuid, p_from date, p_to date)
returns table(id uuid, name text, phone text, created_at timestamptz, day date, temperature text,
              campaign text, adset text, ad text, warm boolean, not_interested boolean, closed boolean)
language plpgsql stable security definer set search_path = '' as $$
declare f public.funnels;
begin
  select * into f from public.funnels x where x.id = p_funnel;
  if f.id is null or not private.has_permission(f.tenant_id, 'funnels', 'view') then return; end if;
  return query
  select l.id, trim(concat_ws(' ', l.first_name, l.last_name)), l.phone, l.created_at, (l.created_at at time zone 'Asia/Kolkata')::date,
         l.temperature, l.ad_campaign, l.ad_adset, l.ad_name,
         coalesce(l.temperature = 'warm', false),
         coalesce(l.temperature = 'not_interested' or s.kind = 'lost', false),
         coalesce(l.temperature = 'closed' or s.kind = 'won', false)
    from public.leads l
    left join public.funnel_stages s on s.id = l.stage_id
   where l.funnel_id = f.id and not l.is_archived
     and l.created_at >= (p_from::timestamp at time zone 'Asia/Kolkata')
     and l.created_at < ((p_to + 1)::timestamp at time zone 'Asia/Kolkata');
end $$;
revoke all on function public.funnel_ad_leads(uuid, date, date) from public, anon;
grant execute on function public.funnel_ad_leads(uuid, date, date) to authenticated;
