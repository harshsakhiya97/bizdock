-- Google Ads (spend only): System Connections → Google Ads (keys: developer token, OAuth client ID / secret, refresh
-- token, manager ID, customer IDs). The google-ads function lists the ad accounts, then every 3 hours pulls their
-- campaigns, ad groups and ads, and the numbers per day at campaign, ad group and ad level. Funnels add whole campaigns
-- (Funnel → Google Ads); the funnel Overview can show Facebook, Google or both.

-- the provider
alter table public.integrations drop constraint if exists integrations_provider_check;
alter table public.integrations add constraint integrations_provider_check
  check (provider = any (array['whatsapp','callyzer','zoom','voice_call','perisclaw','facebook_ads','razorpay','google_ads']));

-- ---- ad accounts and what's in them ----
create table if not exists public.google_ad_accounts (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  integration_id uuid references public.integrations(id) on delete set null,
  customer_id text not null,              -- 10 digits, no dashes
  name text,
  currency text,
  timezone text,
  is_manager boolean not null default false,
  is_enabled boolean not null default true,
  gst_rate numeric(5, 2) not null default 18,
  backfill_from date,
  synced_until date,
  last_full_at date,
  last_sync_at timestamptz,
  last_error text,
  lock_until timestamptz,
  structure_at timestamptz,
  created_at timestamptz not null default now(),
  unique (tenant_id, customer_id)
);
create table if not exists public.google_campaigns (
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  campaign_id text not null,
  account_id uuid not null references public.google_ad_accounts(id) on delete cascade,
  name text,
  status text,                            -- ENABLED / PAUSED / REMOVED
  channel text,                           -- SEARCH / DISPLAY / VIDEO / PERFORMANCE_MAX …
  start_date date,
  updated_at timestamptz not null default now(),
  primary key (tenant_id, campaign_id)
);
create table if not exists public.google_ad_groups (
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  ad_group_id text not null,
  campaign_id text not null,
  account_id uuid not null references public.google_ad_accounts(id) on delete cascade,
  name text,
  status text,
  updated_at timestamptz not null default now(),
  primary key (tenant_id, ad_group_id)
);
create table if not exists public.google_ads (
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  ad_id text not null,
  ad_group_id text not null,
  campaign_id text not null,
  account_id uuid not null references public.google_ad_accounts(id) on delete cascade,
  name text,
  type text,                              -- RESPONSIVE_SEARCH_AD / RESPONSIVE_DISPLAY_AD / VIDEO_AD …
  status text,
  final_urls jsonb not null default '[]'::jsonb,
  headlines jsonb not null default '[]'::jsonb,
  descriptions jsonb not null default '[]'::jsonb,
  updated_at timestamptz not null default now(),
  primary key (tenant_id, ad_id, ad_group_id)
);
-- numbers per day at three levels (spend without GST, in the account's currency). campaign: every campaign, Performance
-- Max too (no ads); ad_group / ad: the breakdown
create table if not exists public.google_insights (
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  account_id uuid not null references public.google_ad_accounts(id) on delete cascade,
  level text not null check (level in ('campaign', 'ad_group', 'ad')),
  day date not null,
  campaign_id text not null,
  ad_group_id text not null default '',
  ad_id text not null default '',
  spend numeric(14, 2) not null default 0,
  impressions bigint,
  clicks int,
  conversions numeric(14, 2),
  updated_at timestamptz not null default now(),
  primary key (tenant_id, level, campaign_id, ad_group_id, ad_id, day)
);
create index if not exists google_insights_day on public.google_insights (tenant_id, level, day);

-- a funnel's Google campaigns (whole campaigns; a campaign belongs to one funnel)
create table if not exists public.funnel_google_links (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  funnel_id uuid not null references public.funnels(id) on delete cascade,
  campaign_id text not null,
  created_at timestamptz not null default now(),
  unique (tenant_id, campaign_id)
);

-- ---- access: funnel viewers and System Connections people read; System Connections people switch accounts ----
do $$
declare t text;
begin
  foreach t in array array['google_ad_accounts', 'google_campaigns', 'google_ad_groups', 'google_ads', 'google_insights', 'funnel_google_links'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists "%1$s: read" on public.%1$s', t);
    execute format($p$create policy "%1$s: read" on public.%1$s for select to authenticated
      using (private.has_permission(tenant_id, 'funnels', 'view') or private.has_permission(tenant_id, 'settings', 'edit'))$p$, t);
    execute format('grant select on public.%I to authenticated', t);
  end loop;
end $$;
drop policy if exists "google_ad_accounts: write" on public.google_ad_accounts;
create policy "google_ad_accounts: write" on public.google_ad_accounts for update to authenticated
  using (private.has_permission(tenant_id, 'settings', 'edit')) with check (private.has_permission(tenant_id, 'settings', 'edit'));
grant update (is_enabled, gst_rate) on public.google_ad_accounts to authenticated;
drop policy if exists "funnel_google_links: write" on public.funnel_google_links;
create policy "funnel_google_links: write" on public.funnel_google_links for all to authenticated
  using (private.has_permission(tenant_id, 'funnels', 'edit')) with check (private.has_permission(tenant_id, 'funnels', 'edit'));
grant insert, delete on public.funnel_google_links to authenticated;

-- may the caller start a pull now (System Connections, or funnel editors from the funnel's Google Ads tab)
create or replace function public.can_sync_google(p_tenant uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select private.has_permission(p_tenant, 'settings', 'edit') or private.has_permission(p_tenant, 'funnels', 'edit')
$$;
revoke all on function public.can_sync_google(uuid) from public, anon;
grant execute on function public.can_sync_google(uuid) to authenticated;

-- ---- every 3 hours while a Google Ads account is on ----
create or replace function private.kick_google(p_body jsonb) returns void
language sql security definer set search_path = '' as $$
  select net.http_post(
    url := 'https://tnnjudehqalkgglzkfik.supabase.co/functions/v1/google-ads',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-secret', public.workflow_cron_secret()),
    body := p_body,
    timeout_milliseconds := 150000
  );
$$;
do $$
begin
  perform cron.unschedule('google-ads-pull') where exists (select 1 from cron.job where jobname = 'google-ads-pull');
  perform cron.schedule('google-ads-pull', '41 */3 * * *', $c$
    select private.kick_google('{"action":"cron"}'::jsonb)
     where exists (select 1 from public.google_ad_accounts a join public.integrations i on i.id = a.integration_id
                    where a.is_enabled and not a.is_manager and i.is_enabled and i.status = 'connected');
  $c$);
end $$;
