-- Facebook (Meta) ads: "Continue with Facebook" (Facebook Login for Business, BizDock's Meta app, read-only ads_read) adds a
-- connection (an integrations row, provider facebook_ads) with the ad accounts the person picked. Every day the ad accounts'
-- numbers per ad and day are pulled (meta-ads function). Funnels link whole campaigns or some of their ad sets; the funnel's
-- Overview reports spend (with GST) → leads → won → revenue → collected → balance.

-- one try to connect (made when the popup opens, used once by Facebook's return)
create table if not exists public.meta_oauth_states (
  id text primary key,
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  member_id uuid references public.tenant_members(id) on delete set null,
  user_id uuid not null,
  integration_id uuid references public.integrations(id) on delete cascade,
  result jsonb,
  created_at timestamptz not null default now(),
  used_at timestamptz
);
alter table public.meta_oauth_states enable row level security;

-- the connection's Facebook login (server only)
create table if not exists public.meta_tokens (
  integration_id uuid primary key references public.integrations(id) on delete cascade,
  access_token text not null,
  token_type text,
  expires_at timestamptz,
  scope text,
  updated_at timestamptz not null default now()
);
alter table public.meta_tokens enable row level security;
revoke all on public.meta_oauth_states, public.meta_tokens from anon, authenticated;

create or replace function public.meta_oauth_result(p_state text) returns jsonb
language sql stable security definer set search_path = '' as $$
  select s.result from public.meta_oauth_states s where s.id = p_state and s.user_id = auth.uid()
$$;
revoke all on function public.meta_oauth_result(text) from public, anon;
grant execute on function public.meta_oauth_result(text) to authenticated;

-- ---- ad accounts and what's in them ----
create table if not exists public.meta_ad_accounts (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  integration_id uuid not null references public.integrations(id) on delete cascade,
  act_id text not null,                 -- act_123…
  name text,
  currency text,
  timezone text,
  account_status int,
  business_name text,
  is_enabled boolean not null default true,
  gst_rate numeric(5, 2) not null default 18,
  backfill_from date,                   -- pull history from this day (set on connect)
  synced_until date,                    -- history pulled up to (inclusive)
  last_full_at date,                    -- the day the last 7 days were pulled again
  last_sync_at timestamptz,
  last_error text,
  created_at timestamptz not null default now(),
  unique (tenant_id, act_id)
);

create table if not exists public.meta_campaigns (
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  campaign_id text not null,
  account_id uuid not null references public.meta_ad_accounts(id) on delete cascade,
  name text,
  status text,
  effective_status text,
  objective text,
  created_time timestamptz,
  updated_at timestamptz not null default now(),
  primary key (tenant_id, campaign_id)
);
create table if not exists public.meta_adsets (
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  adset_id text not null,
  campaign_id text not null,
  account_id uuid not null references public.meta_ad_accounts(id) on delete cascade,
  name text,
  status text,
  effective_status text,
  updated_at timestamptz not null default now(),
  primary key (tenant_id, adset_id)
);
create table if not exists public.meta_ads (
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  ad_id text not null,
  adset_id text not null,
  campaign_id text not null,
  account_id uuid not null references public.meta_ad_accounts(id) on delete cascade,
  name text,
  status text,
  effective_status text,
  updated_at timestamptz not null default now(),
  primary key (tenant_id, ad_id)
);
-- every name a campaign / ad set / ad has had (leads carry names, which can change)
create table if not exists public.meta_names (
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  level text not null check (level in ('campaign', 'adset', 'ad')),
  object_id text not null,
  name text not null,
  first_seen timestamptz not null default now(),
  primary key (tenant_id, level, object_id, name)
);
create index if not exists meta_names_name on public.meta_names (tenant_id, level, lower(name));

-- numbers per ad per day (spend without GST, in the account's currency)
create table if not exists public.meta_insights (
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  account_id uuid not null references public.meta_ad_accounts(id) on delete cascade,
  day date not null,
  campaign_id text not null,
  adset_id text not null,
  ad_id text not null,
  spend numeric(14, 2) not null default 0,
  impressions bigint,
  reach bigint,
  frequency numeric(10, 4),
  clicks int,
  link_clicks int,
  ctr numeric(10, 4),
  cpc numeric(12, 4),
  cpm numeric(12, 4),
  landing_page_views int,
  leads int,
  purchases int,
  actions jsonb,
  updated_at timestamptz not null default now(),
  primary key (tenant_id, ad_id, day)
);
create index if not exists meta_insights_campaign on public.meta_insights (tenant_id, campaign_id, day);
create index if not exists meta_insights_adset on public.meta_insights (tenant_id, adset_id, day);

-- a funnel's campaigns: the whole campaign (adset_id null) or some of its ad sets
create table if not exists public.funnel_ad_links (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  funnel_id uuid not null references public.funnels(id) on delete cascade,
  campaign_id text not null,
  adset_id text,
  created_at timestamptz not null default now()
);
create unique index if not exists funnel_ad_links_one on public.funnel_ad_links (tenant_id, campaign_id, coalesce(adset_id, ''));

-- an ad set belongs to one funnel: no whole-campaign link next to another funnel's ad set links (and the other way)
create or replace function private.funnel_ad_links_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
declare f text;
begin
  select fu.name into f from public.funnel_ad_links x join public.funnels fu on fu.id = x.funnel_id
   where x.tenant_id = new.tenant_id and x.campaign_id = new.campaign_id and x.funnel_id <> new.funnel_id
     and (new.adset_id is null or x.adset_id is null or x.adset_id = new.adset_id)
   limit 1;
  if f is not null then raise exception 'Already linked to the funnel “%”.', f; end if;
  return new;
end $$;
drop trigger if exists funnel_ad_links_guard on public.funnel_ad_links;
create trigger funnel_ad_links_guard before insert or update on public.funnel_ad_links for each row execute function private.funnel_ad_links_guard();

-- ---- access: funnels people read; System Connections people change accounts, funnel editors link campaigns ----
alter table public.meta_ad_accounts enable row level security;
alter table public.meta_campaigns enable row level security;
alter table public.meta_adsets enable row level security;
alter table public.meta_ads enable row level security;
alter table public.meta_names enable row level security;
alter table public.meta_insights enable row level security;
alter table public.funnel_ad_links enable row level security;

do $$
declare t text;
begin
  foreach t in array array['meta_ad_accounts', 'meta_campaigns', 'meta_adsets', 'meta_ads', 'meta_names', 'meta_insights', 'funnel_ad_links'] loop
    execute format('drop policy if exists "%1$s: read" on public.%1$s', t);
    execute format($p$create policy "%1$s: read" on public.%1$s for select to authenticated
      using (private.has_permission(tenant_id, 'funnels', 'view') or private.has_permission(tenant_id, 'settings', 'edit'))$p$, t);
    execute format('grant select on public.%I to authenticated', t);
  end loop;
end $$;

drop policy if exists "meta_ad_accounts: write" on public.meta_ad_accounts;
create policy "meta_ad_accounts: write" on public.meta_ad_accounts for update to authenticated
  using (private.has_permission(tenant_id, 'settings', 'edit')) with check (private.has_permission(tenant_id, 'settings', 'edit'));
grant update (is_enabled, gst_rate) on public.meta_ad_accounts to authenticated;

drop policy if exists "funnel_ad_links: write" on public.funnel_ad_links;
create policy "funnel_ad_links: write" on public.funnel_ad_links for all to authenticated
  using (private.has_permission(tenant_id, 'funnels', 'edit')) with check (private.has_permission(tenant_id, 'funnels', 'edit'));
grant insert, delete on public.funnel_ad_links to authenticated;

-- ---- the meta-ads function writes (service role) ----
-- a day range of one ad account, replaced with Meta's numbers (and the campaigns / ad sets / ads / names they mention)
create or replace function public.meta_insights_put(p_account uuid, p_since date, p_until date, p_rows jsonb, p_clear boolean)
returns int language plpgsql security definer set search_path = '' as $$
declare
  a public.meta_ad_accounts;
  n int;
begin
  select * into a from public.meta_ad_accounts where id = p_account;
  if a.id is null then return 0; end if;
  if p_clear then delete from public.meta_insights where account_id = a.id and day between p_since and p_until; end if;

  insert into public.meta_campaigns (tenant_id, campaign_id, account_id, name)
  select distinct on (r ->> 'campaign_id') a.tenant_id, r ->> 'campaign_id', a.id, r ->> 'campaign_name' from jsonb_array_elements(p_rows) r
   order by r ->> 'campaign_id', r ->> 'date_start' desc
  on conflict (tenant_id, campaign_id) do update set name = coalesce(public.meta_campaigns.name, excluded.name);
  insert into public.meta_adsets (tenant_id, adset_id, campaign_id, account_id, name)
  select distinct on (r ->> 'adset_id') a.tenant_id, r ->> 'adset_id', r ->> 'campaign_id', a.id, r ->> 'adset_name' from jsonb_array_elements(p_rows) r
   order by r ->> 'adset_id', r ->> 'date_start' desc
  on conflict (tenant_id, adset_id) do update set name = coalesce(public.meta_adsets.name, excluded.name);
  insert into public.meta_ads (tenant_id, ad_id, adset_id, campaign_id, account_id, name)
  select distinct on (r ->> 'ad_id') a.tenant_id, r ->> 'ad_id', r ->> 'adset_id', r ->> 'campaign_id', a.id, r ->> 'ad_name' from jsonb_array_elements(p_rows) r
   order by r ->> 'ad_id', r ->> 'date_start' desc
  on conflict (tenant_id, ad_id) do update set name = coalesce(public.meta_ads.name, excluded.name);
  insert into public.meta_names (tenant_id, level, object_id, name)
  select distinct a.tenant_id, l.level, l.id, l.name from jsonb_array_elements(p_rows) r
   cross join lateral (values ('campaign', r ->> 'campaign_id', r ->> 'campaign_name'), ('adset', r ->> 'adset_id', r ->> 'adset_name'), ('ad', r ->> 'ad_id', r ->> 'ad_name')) l(level, id, name)
   where coalesce(l.name, '') <> ''
  on conflict do nothing;

  with ins as (
    insert into public.meta_insights (tenant_id, account_id, day, campaign_id, adset_id, ad_id, spend, impressions, reach, frequency, clicks, link_clicks,
                                      ctr, cpc, cpm, landing_page_views, leads, purchases, actions, updated_at)
    select a.tenant_id, a.id, (r ->> 'date_start')::date, r ->> 'campaign_id', r ->> 'adset_id', r ->> 'ad_id',
           coalesce((r ->> 'spend')::numeric, 0), (r ->> 'impressions')::bigint, (r ->> 'reach')::bigint, (r ->> 'frequency')::numeric,
           (r ->> 'clicks')::int, (r ->> 'inline_link_clicks')::int, (r ->> 'ctr')::numeric, (r ->> 'cpc')::numeric, (r ->> 'cpm')::numeric,
           (select sum((x ->> 'value')::numeric)::int from jsonb_array_elements(coalesce(r -> 'actions', '[]')) x where x ->> 'action_type' = 'landing_page_view'),
           (select max((x ->> 'value')::numeric)::int from jsonb_array_elements(coalesce(r -> 'actions', '[]')) x
             where x ->> 'action_type' in ('lead', 'onsite_conversion.lead_grouped', 'offsite_conversion.fb_pixel_lead')),
           (select max((x ->> 'value')::numeric)::int from jsonb_array_elements(coalesce(r -> 'actions', '[]')) x
             where x ->> 'action_type' in ('purchase', 'offsite_conversion.fb_pixel_purchase', 'omni_purchase')),
           r -> 'actions', now()
      from jsonb_array_elements(p_rows) r
    on conflict (tenant_id, ad_id, day) do update set
      spend = excluded.spend, impressions = excluded.impressions, reach = excluded.reach, frequency = excluded.frequency, clicks = excluded.clicks,
      link_clicks = excluded.link_clicks, ctr = excluded.ctr, cpc = excluded.cpc, cpm = excluded.cpm, landing_page_views = excluded.landing_page_views,
      leads = excluded.leads, purchases = excluded.purchases, actions = excluded.actions, updated_at = now()
    returning 1)
  select count(*) into n from ins;
  return n;
end $$;
revoke all on function public.meta_insights_put(uuid, date, date, jsonb, boolean) from public, anon, authenticated;
grant execute on function public.meta_insights_put(uuid, date, date, jsonb, boolean) to service_role;

-- campaigns / ad sets / ads as Meta lists them now (status, objective; renames are remembered in meta_names)
create or replace function public.meta_structure_put(p_account uuid, p_level text, p_rows jsonb) returns int
language plpgsql security definer set search_path = '' as $$
declare
  a public.meta_ad_accounts;
  n int;
begin
  select * into a from public.meta_ad_accounts where id = p_account;
  if a.id is null then return 0; end if;
  if p_level = 'campaign' then
    insert into public.meta_campaigns (tenant_id, campaign_id, account_id, name, status, effective_status, objective, created_time, updated_at)
    select a.tenant_id, r ->> 'id', a.id, r ->> 'name', r ->> 'status', r ->> 'effective_status', r ->> 'objective', (r ->> 'created_time')::timestamptz, now()
      from jsonb_array_elements(p_rows) r
    on conflict (tenant_id, campaign_id) do update set name = excluded.name, status = excluded.status, effective_status = excluded.effective_status,
      objective = excluded.objective, created_time = excluded.created_time, account_id = excluded.account_id, updated_at = now();
  elsif p_level = 'adset' then
    insert into public.meta_adsets (tenant_id, adset_id, campaign_id, account_id, name, status, effective_status, updated_at)
    select a.tenant_id, r ->> 'id', r ->> 'campaign_id', a.id, r ->> 'name', r ->> 'status', r ->> 'effective_status', now() from jsonb_array_elements(p_rows) r
    on conflict (tenant_id, adset_id) do update set name = excluded.name, status = excluded.status, effective_status = excluded.effective_status,
      campaign_id = excluded.campaign_id, updated_at = now();
  else
    insert into public.meta_ads (tenant_id, ad_id, adset_id, campaign_id, account_id, name, status, effective_status, updated_at)
    select a.tenant_id, r ->> 'id', r ->> 'adset_id', r ->> 'campaign_id', a.id, r ->> 'name', r ->> 'status', r ->> 'effective_status', now() from jsonb_array_elements(p_rows) r
    on conflict (tenant_id, ad_id) do update set name = excluded.name, status = excluded.status, effective_status = excluded.effective_status,
      adset_id = excluded.adset_id, campaign_id = excluded.campaign_id, updated_at = now();
  end if;
  get diagnostics n = row_count;
  insert into public.meta_names (tenant_id, level, object_id, name)
  select a.tenant_id, p_level, r ->> 'id', r ->> 'name' from jsonb_array_elements(p_rows) r where coalesce(r ->> 'name', '') <> ''
  on conflict do nothing;
  return n;
end $$;
revoke all on function public.meta_structure_put(uuid, text, jsonb) from public, anon, authenticated;
grant execute on function public.meta_structure_put(uuid, text, jsonb) to service_role;

-- ---- pulls: every 3 hours (today and yesterday), the last 7 days again once a day, history in steps ----
create or replace function private.kick_meta(p_body jsonb) returns void
language sql security definer set search_path = '' as $$
  select net.http_post(
    url := 'https://tnnjudehqalkgglzkfik.supabase.co/functions/v1/meta-ads',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-secret', public.workflow_cron_secret()),
    body := p_body,
    timeout_milliseconds := 150000
  );
$$;
do $$
begin
  perform cron.unschedule('meta-ads-pull') where exists (select 1 from cron.job where jobname = 'meta-ads-pull');
  perform cron.schedule('meta-ads-pull', '23 */3 * * *', $c$
    select private.kick_meta('{"action":"cron"}'::jsonb)
     where exists (select 1 from public.meta_ad_accounts a join public.integrations i on i.id = a.integration_id
                    where a.is_enabled and i.is_enabled and i.status = 'connected');
  $c$);
end $$;

-- one pull at a time per ad account; when its campaigns / ad sets / ads were last listed
alter table public.meta_ad_accounts add column if not exists lock_until timestamptz;
alter table public.meta_ad_accounts add column if not exists structure_at timestamptz;

-- may the caller start a pull now (System Connections, or funnel editors from the funnel's Facebook Ads tab)
create or replace function public.can_sync_meta(p_tenant uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select private.has_permission(p_tenant, 'settings', 'edit') or private.has_permission(p_tenant, 'funnels', 'edit')
$$;
revoke all on function public.can_sync_meta(uuid) from public, anon;
grant execute on function public.can_sync_meta(uuid) to authenticated;

-- disconnecting a Facebook login keeps its ad accounts and their numbers (reconnecting picks them up again)
alter table public.meta_ad_accounts alter column integration_id drop not null;
alter table public.meta_ad_accounts drop constraint if exists meta_ad_accounts_integration_id_fkey;
alter table public.meta_ad_accounts add constraint meta_ad_accounts_integration_id_fkey foreign key (integration_id) references public.integrations(id) on delete set null;
