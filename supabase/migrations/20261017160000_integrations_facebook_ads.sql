-- Facebook Ads account as a system connection (allowed per client in admin → Connections, like the others).
alter table public.integrations drop constraint integrations_provider_check;
alter table public.integrations add constraint integrations_provider_check
  check (provider in ('whatsapp', 'callyzer', 'zoom', 'voice_call', 'perisclaw', 'facebook_ads'));
