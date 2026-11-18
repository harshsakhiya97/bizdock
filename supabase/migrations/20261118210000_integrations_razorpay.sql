-- System Connections → Razorpay: allow the 'razorpay' provider
alter table public.integrations drop constraint if exists integrations_provider_check;
alter table public.integrations add constraint integrations_provider_check
  check (provider = any (array['whatsapp','callyzer','zoom','voice_call','perisclaw','facebook_ads','razorpay']));
