-- Zoom "Connect with Zoom": a popup to Zoom's own login and consent (BizDock's Zoom app, OAuth), instead of each workspace
-- making a Server-to-Server app and pasting its keys. The connected account is a normal Zoom row in integrations
-- (config.auth = 'oauth'); its tokens live in zoom_oauth_tokens, which only the server reads.

-- one try to connect: made when the popup opens, used once by Zoom's return (zoom-oauth function)
create table if not exists public.zoom_oauth_states (
  id text primary key,
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  member_id uuid references public.tenant_members(id) on delete set null,
  user_id uuid not null,
  -- Reconnect: the account it renews
  integration_id uuid references public.integrations(id) on delete cascade,
  -- what the popup shows / the app reads back: {ok, message, integration_id}
  result jsonb,
  created_at timestamptz not null default now(),
  used_at timestamptz
);
alter table public.zoom_oauth_states enable row level security;

-- the account's Zoom login (the hour-long token and the key that renews it)
create table if not exists public.zoom_oauth_tokens (
  integration_id uuid primary key references public.integrations(id) on delete cascade,
  access_token text not null,
  refresh_token text not null,
  expires_at timestamptz not null,
  scope text,
  updated_at timestamptz not null default now()
);
alter table public.zoom_oauth_tokens enable row level security;
revoke all on public.zoom_oauth_states, public.zoom_oauth_tokens from anon, authenticated;

-- may the caller connect accounts in this workspace (Settings & integrations)
create or replace function public.can_manage_integrations(p_tenant uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select private.has_permission(p_tenant, 'settings', 'edit')
$$;
revoke all on function public.can_manage_integrations(uuid) from public, anon;
grant execute on function public.can_manage_integrations(uuid) to authenticated;

-- the app asks how its try went (only the person who started it)
create or replace function public.zoom_oauth_result(p_state text) returns jsonb
language sql stable security definer set search_path = '' as $$
  select s.result from public.zoom_oauth_states s where s.id = p_state and s.user_id = auth.uid()
$$;
revoke all on function public.zoom_oauth_result(text) from public, anon;
grant execute on function public.zoom_oauth_result(text) to authenticated;
