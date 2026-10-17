-- A workspace can connect several Facebook ad accounts; every other service stays one per workspace.
alter table public.integrations add column label text;   -- e.g. the ad account's name
alter table public.integrations drop constraint integrations_tenant_id_provider_key;
create unique index integrations_one_per_provider on public.integrations (tenant_id, provider) where provider <> 'facebook_ads';
create unique index integrations_fb_account on public.integrations (tenant_id, (config ->> 'ad_account_id')) where provider = 'facebook_ads';
