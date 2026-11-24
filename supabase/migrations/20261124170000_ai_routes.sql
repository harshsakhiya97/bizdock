-- System Connections → AI order: per AI feature, which AI is tried first (Level 1), then next (Level 2, 3) when it
-- fails, the failures that move on to the next level, on / off and (Lead AI Insights) the prompt.
--   feature: lead_insight (each lead's summary) · insights (the AI Insights button) · ai_call_template (Write with AI)
--   levels: [{ "provider": "gemini" | "claude", "model": "" (empty = the connection's model) }, …] in order
--   fail_on: busy · error · bad_answer · not_connected
-- No row = Gemini, then Claude, every failure, on.
create table if not exists public.ai_routes (
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  feature text not null check (feature in ('lead_insight', 'insights', 'ai_call_template')),
  enabled boolean not null default true,
  levels jsonb not null default '[{"provider":"gemini","model":""},{"provider":"claude","model":""}]'::jsonb,
  fail_on text[] not null default array['busy', 'error', 'bad_answer', 'not_connected'],
  prompt text,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  primary key (tenant_id, feature)
);
alter table public.ai_routes enable row level security;
drop policy if exists "ai_routes: read" on public.ai_routes;
create policy "ai_routes: read" on public.ai_routes for select to authenticated
  using (private.has_permission(tenant_id, 'settings', 'view') or private.has_permission(tenant_id, 'settings', 'edit'));
drop policy if exists "ai_routes: write" on public.ai_routes;
create policy "ai_routes: write" on public.ai_routes for all to authenticated
  using (private.has_permission(tenant_id, 'settings', 'edit'))
  with check (private.has_permission(tenant_id, 'settings', 'edit'));
grant select, insert, update, delete on public.ai_routes to authenticated;

-- what was set on the Gemini connection (Prompt & steps → Lead AI Insights) moves here
insert into public.ai_routes (tenant_id, feature, enabled, levels, fail_on, prompt)
select i.tenant_id, 'lead_insight', coalesce(i.config->>'li_on', 'on') <> 'off',
       case when coalesce(i.config->>'li_fallback', 'on') = 'off' then '[{"provider":"gemini","model":""}]'::jsonb
            else '[{"provider":"gemini","model":""},{"provider":"claude","model":""}]'::jsonb end,
       coalesce(string_to_array(nullif(i.config->>'li_when', ''), ','), array['busy', 'error', 'bad_answer', 'not_connected']),
       nullif(i.config->>'li_prompt', '')
  from public.integrations i
 where i.provider = 'gemini' and (i.config ? 'li_on' or i.config ? 'li_fallback' or i.config ? 'li_when' or i.config ? 'li_prompt')
on conflict (tenant_id, feature) do nothing;

-- Lead AI Insights can run for the workspace: on, and one of its levels' AIs is connected
create or replace function private.lead_ai_ready(t uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  with r as (select enabled, levels from public.ai_routes where tenant_id = t and feature = 'lead_insight')
  select coalesce((select enabled from r), true)
     and exists (
       select 1 from public.integrations i
        where i.tenant_id = t and i.is_enabled and coalesce(i.config->>'api_key', '') <> ''
          and i.provider in (
            select x->>'provider' from jsonb_array_elements(coalesce((select levels from r), '[{"provider":"gemini"},{"provider":"claude"}]'::jsonb)) x))
$$;
