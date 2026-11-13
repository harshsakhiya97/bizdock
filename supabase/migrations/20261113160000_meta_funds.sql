-- An ad account's money on Facebook, pulled with its numbers: prepaid funds left (from funding_source_details), amount due
-- (balance), amount spent and the spending limit (minor units, e.g. paise, as Facebook sends them).
alter table public.meta_ad_accounts
  add column if not exists funds jsonb,
  add column if not exists funds_at timestamptz;
