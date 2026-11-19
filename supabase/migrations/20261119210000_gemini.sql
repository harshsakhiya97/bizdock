-- System Connections → Gemini AI (one API key per workspace, and the model to use). The gemini function checks the key
-- and lists the models; AI features (AI Insights, later) call Gemini through it and log their tokens in ai_usage, which
-- the card shows as this month's tokens and an estimated amount (the workspace's own price per 1M tokens).
alter table public.integrations drop constraint if exists integrations_provider_check;
alter table public.integrations add constraint integrations_provider_check
  check (provider = any (array['whatsapp','callyzer','zoom','voice_call','perisclaw','facebook_ads','razorpay','google_ads','gemini']));

create table if not exists public.ai_usage (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  integration_id uuid references public.integrations(id) on delete set null,
  model text,
  feature text,                     -- e.g. insights
  input_tokens int not null default 0,
  output_tokens int not null default 0,
  member_id uuid references public.tenant_members(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists ai_usage_tenant_time on public.ai_usage (tenant_id, created_at desc);
alter table public.ai_usage enable row level security;
drop policy if exists "ai_usage: read" on public.ai_usage;
create policy "ai_usage: read" on public.ai_usage for select to authenticated using (private.has_permission(tenant_id, 'settings', 'edit'));
grant select on public.ai_usage to authenticated;

-- this month's tokens (India time), per model
create or replace function public.ai_usage_month(p_tenant uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('model', model, 'calls', calls, 'input', inp, 'output', outp)), '[]'::jsonb)
    from (select coalesce(u.model, '') model, count(*) calls, sum(u.input_tokens) inp, sum(u.output_tokens) outp
            from public.ai_usage u
           where u.tenant_id = p_tenant and private.has_permission(p_tenant, 'settings', 'edit')
             and u.created_at >= date_trunc('month', now() at time zone 'Asia/Kolkata') at time zone 'Asia/Kolkata'
           group by 1) x
$$;
revoke all on function public.ai_usage_month(uuid) from public, anon;
grant execute on function public.ai_usage_month(uuid) to authenticated;
