-- Calls (phone calls of leads: imported now, Callyzer later), Ad spend (day-wise per funnel), and a one-time staging
-- area for importing an old CRM's backup (rows pushed with a short-lived token, then moved into BizDock's tables).

create table if not exists public.calls (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  business_id uuid references public.businesses(id) on delete set null,
  sub_business_id uuid references public.sub_businesses(id) on delete set null,
  lead_id uuid references public.leads(id) on delete set null,
  member_id uuid references public.tenant_members(id) on delete set null,
  phone text,
  agent_phone text,
  direction text not null default 'outgoing' check (direction in ('incoming', 'outgoing', 'missed', 'rejected', 'unknown')),
  started_at timestamptz not null,
  duration_sec int,
  outcome text,
  purpose text,
  recording_url text,
  recording_file text,
  transcript text,
  ai jsonb,
  ai_status text,
  interest_score int,
  budget_signal text,
  timeline_signal text,
  followup_days int,
  source text not null default 'manual' check (source in ('callyzer', 'manual', 'import')),
  external_id text,
  created_at timestamptz not null default now()
);
create unique index if not exists calls_external on public.calls (tenant_id, source, external_id) where external_id is not null;
create index if not exists calls_lead on public.calls (lead_id, started_at desc);
create index if not exists calls_tenant_time on public.calls (tenant_id, started_at desc);
alter table public.calls enable row level security;
drop policy if exists "calls: read" on public.calls;
create policy "calls: read" on public.calls for select to authenticated using (private.is_member(tenant_id));
grant select on public.calls to authenticated;

create table if not exists public.ad_spend (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  business_id uuid references public.businesses(id) on delete set null,
  sub_business_id uuid references public.sub_businesses(id) on delete set null,
  funnel_id uuid not null references public.funnels(id) on delete cascade,
  spend_date date not null,
  amount numeric(12, 2) not null default 0,
  leads int,
  bookings int,
  impressions int,
  clicks int,
  landing_page_views int,
  add_to_cart int,
  purchases int,
  notes text,
  source text not null default 'manual',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (funnel_id, spend_date)
);
alter table public.ad_spend enable row level security;
drop policy if exists "ad_spend: read" on public.ad_spend;
create policy "ad_spend: read" on public.ad_spend for select to authenticated using (private.is_member(tenant_id));
drop policy if exists "ad_spend: write" on public.ad_spend;
create policy "ad_spend: write" on public.ad_spend for all to authenticated
  using (private.has_permission(tenant_id, 'settings', 'edit')) with check (private.has_permission(tenant_id, 'settings', 'edit'));
grant select, insert, update, delete on public.ad_spend to authenticated;

-- ---- one-time import staging ----
create table if not exists private.import_tokens (token text primary key, purpose text not null, expires_at timestamptz not null);
create table if not exists private.import_rows (id bigserial primary key, purpose text not null, kind text not null, data jsonb not null, created_at timestamptz not null default now());

-- a script pushes the backup's rows (a batch per call) with a token that expires
create or replace function public.import_put(p_token text, p_kind text, p_rows jsonb) returns int
language plpgsql security definer set search_path = '' as $$
declare
  t private.import_tokens;
  n int;
begin
  select * into t from private.import_tokens where token = p_token and expires_at > now();
  if t.token is null then raise exception 'Import link expired.'; end if;
  insert into private.import_rows (purpose, kind, data) select t.purpose, p_kind, x from jsonb_array_elements(p_rows) x;
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.import_put(text, text, jsonb) from public;
grant execute on function public.import_put(text, text, jsonb) to anon, authenticated;
