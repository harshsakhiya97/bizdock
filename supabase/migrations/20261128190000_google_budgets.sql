-- Google campaign budgets (daily amount; total for a campaign total budget), in the account currency
alter table public.google_campaigns add column if not exists daily_budget numeric, add column if not exists total_budget numeric;
-- the next sync reads campaigns again, with their budgets
update public.google_ad_accounts set structure_at = null;
