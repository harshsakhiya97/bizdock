-- Funnel → Sheets → Ad campaign: a sheet tied to a Facebook / Google campaign gives its leads that campaign (Campaign
-- Name) and Source Facebook / Google. Changing (or clearing) it updates the sheet's leads at once — without rewriting
-- their AI Insights (bizdock.quiet).
alter table public.funnel_sheets add column if not exists ad_platform text check (ad_platform in ('meta', 'google'));
alter table public.funnel_sheets add column if not exists ad_campaign_id text;

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
  sh_plat text;
  sh_camp text;
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

  -- a Google Sheet: its ad campaign (Sheets → Ad campaign) is the lead's campaign; else, with no ad info, the sheet's name
  if l.sheet_id is not null then
    select s.ad_platform,
           case s.ad_platform
             when 'meta' then (select c.name from public.meta_campaigns c where c.tenant_id = s.tenant_id and c.campaign_id = s.ad_campaign_id)
             when 'google' then (select c.name from public.google_campaigns c where c.tenant_id = s.tenant_id and c.campaign_id = s.ad_campaign_id)
           end
      into sh_plat, sh_camp
      from public.funnel_sheets s where s.id = l.sheet_id;
    if sh_camp is not null then
      l.ad_campaign := sh_camp;
    elsif l.ad_campaign is null and l.ad_adset is null and l.ad_name is null and coalesce(l.utm_source, '') = '' then
      select s.name into l.ad_campaign from public.funnel_sheets s where s.id = l.sheet_id;
    end if;
  end if;

  if p_source then
    code := coalesce(nullif(trim(l.utm_source), ''), private.url_param(pu, 'utm_source'));
    if sh_camp is not null then
      l.source_id := private.source_id_named(l.tenant_id, case sh_plat when 'google' then 'Google' else 'Facebook' end);
      l.utm_source_pending := null;
    elsif code is not null and code not like '%{{%' then
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

-- a change that only re-tags leads (bizdock.quiet = 1) leaves their AI Insights alone
create or replace function private.lead_insight_on_lead() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if coalesce(current_setting('bizdock.quiet', true), '') = '1' then return null; end if;
  if tg_op = 'UPDATE' and (to_jsonb(old) - 'updated_at' - 'next_follow_up_at') = (to_jsonb(new) - 'updated_at' - 'next_follow_up_at') then
    return null;
  end if;
  perform private.lead_insight_touch(new.id, new.tenant_id);
  return null;
end $$;

create or replace function private.sheet_campaign_changed() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform set_config('bizdock.quiet', '1', true);
  update public.leads l set ad_campaign = x.ad_campaign, ad_adset = x.ad_adset, ad_name = x.ad_name,
         source_id = x.source_id, utm_source_pending = x.utm_source_pending
    from (select f.* from public.leads l2 cross join lateral private.lead_ad_fill(l2, true) f where l2.sheet_id = new.id) x
   where x.id = l.id;
  perform set_config('bizdock.quiet', '', true);
  return null;
end $$;
drop trigger if exists sheet_campaign_link on public.funnel_sheets;
create trigger sheet_campaign_link after update of ad_platform, ad_campaign_id on public.funnel_sheets
  for each row when (old.ad_platform is distinct from new.ad_platform or old.ad_campaign_id is distinct from new.ad_campaign_id)
  execute function private.sheet_campaign_changed();
