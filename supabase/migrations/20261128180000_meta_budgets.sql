-- Campaign / ad set budgets from Facebook (daily or lifetime; CBO at the campaign, ABO at the ad set), in the account currency
alter table public.meta_campaigns add column if not exists daily_budget numeric, add column if not exists lifetime_budget numeric;
alter table public.meta_adsets add column if not exists daily_budget numeric, add column if not exists lifetime_budget numeric;

create or replace function public.meta_structure_put(p_account uuid, p_level text, p_rows jsonb)
 returns integer
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  a public.meta_ad_accounts;
  n int;
begin
  select * into a from public.meta_ad_accounts where id = p_account;
  if a.id is null then return 0; end if;
  if p_level = 'campaign' then
    insert into public.meta_campaigns (tenant_id, campaign_id, account_id, name, status, effective_status, objective, created_time, daily_budget, lifetime_budget, updated_at)
    select a.tenant_id, r ->> 'id', a.id, r ->> 'name', r ->> 'status', r ->> 'effective_status', r ->> 'objective', (r ->> 'created_time')::timestamptz,
           nullif(r ->> 'daily_budget', '')::numeric / 100, nullif(r ->> 'lifetime_budget', '')::numeric / 100, now()
      from jsonb_array_elements(p_rows) r
    on conflict (tenant_id, campaign_id) do update set name = excluded.name, status = excluded.status, effective_status = excluded.effective_status,
      objective = excluded.objective, created_time = excluded.created_time, account_id = excluded.account_id,
      daily_budget = excluded.daily_budget, lifetime_budget = excluded.lifetime_budget, updated_at = now();
  elsif p_level = 'adset' then
    insert into public.meta_adsets (tenant_id, adset_id, campaign_id, account_id, name, status, effective_status, daily_budget, lifetime_budget, updated_at)
    select a.tenant_id, r ->> 'id', r ->> 'campaign_id', a.id, r ->> 'name', r ->> 'status', r ->> 'effective_status',
           nullif(r ->> 'daily_budget', '')::numeric / 100, nullif(r ->> 'lifetime_budget', '')::numeric / 100, now()
      from jsonb_array_elements(p_rows) r
    on conflict (tenant_id, adset_id) do update set name = excluded.name, status = excluded.status, effective_status = excluded.effective_status,
      campaign_id = excluded.campaign_id, daily_budget = excluded.daily_budget, lifetime_budget = excluded.lifetime_budget, updated_at = now();
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
end $function$;

-- the next sync reads campaigns / ad sets again, with their budgets
update public.meta_ad_accounts set structure_at = null;
