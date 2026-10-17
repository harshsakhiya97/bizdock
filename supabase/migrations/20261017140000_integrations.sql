-- System connections: third-party services a workspace connects (WhatsApp, Callyzer, Zoom, voice calls, Perisclaw).
-- One row per provider per workspace. Keys live in `config`; only people with Settings & integrations can read them.

create table public.integrations (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenants(id) on delete cascade,
  provider      text not null check (provider in ('whatsapp', 'callyzer', 'zoom', 'voice_call', 'perisclaw')),
  is_enabled    boolean not null default true,
  config        jsonb not null default '{}'::jsonb,
  status        text not null default 'connected' check (status in ('connected', 'error', 'disconnected')),
  last_error    text,
  connected_by  uuid references public.tenant_members(id) on delete set null,
  connected_at  timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (tenant_id, provider)
);
create trigger integrations_set_updated_at before update on public.integrations
  for each row execute function public.set_updated_at();

alter table public.integrations enable row level security;
create policy "integrations: read" on public.integrations for select to authenticated
  using (private.has_permission(tenant_id, 'settings', 'edit'));
create policy "integrations: write" on public.integrations for all to authenticated
  using (private.has_permission(tenant_id, 'settings', 'edit'))
  with check (private.has_permission(tenant_id, 'settings', 'edit'));

grant select, insert, update, delete on public.integrations to authenticated;
revoke all on public.integrations from anon;
