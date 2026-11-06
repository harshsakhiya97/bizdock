-- WhatsApp logs: every message sent (workflows, the app) and every reply, with delivered / read times from WATI's webhook.
create table if not exists public.whatsapp_logs (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  direction text not null default 'out' check (direction in ('out', 'in')),
  -- 91XXXXXXXXXX (country code, no +)
  phone text not null,
  lead_id uuid references public.leads(id) on delete set null,
  template text,
  body text,
  params jsonb,
  source text not null default 'app' check (source in ('workflow', 'app', 'reply')),
  workflow_id uuid references public.workflows(id) on delete set null,
  run_id uuid,
  status text not null default 'sent' check (status in ('sent', 'delivered', 'read', 'failed', 'received')),
  error text,
  wati_id text,
  sent_at timestamptz not null default now(),
  delivered_at timestamptz,
  read_at timestamptz,
  sent_by uuid references public.tenant_members(id) on delete set null
);
create index if not exists whatsapp_logs_tenant on public.whatsapp_logs (tenant_id, sent_at desc);
create index if not exists whatsapp_logs_phone on public.whatsapp_logs (tenant_id, phone, sent_at desc);
create index if not exists whatsapp_logs_wati on public.whatsapp_logs (wati_id) where wati_id is not null;
alter table public.whatsapp_logs enable row level security;
create policy "whatsapp_logs: read" on public.whatsapp_logs for select using (private.has_permission(tenant_id, 'settings', 'edit'));

-- the workspace's own WATI webhook address (…/wati-webhook?key=…)
create table if not exists public.whatsapp_hooks (
  tenant_id uuid primary key references public.tenants(id) on delete cascade,
  key text not null unique default encode(extensions.gen_random_bytes(18), 'hex'),
  last_event_at timestamptz,
  created_at timestamptz not null default now()
);
alter table public.whatsapp_hooks enable row level security;
create policy "whatsapp_hooks: read" on public.whatsapp_hooks for select using (private.has_permission(tenant_id, 'settings', 'edit'));
create policy "whatsapp_hooks: insert" on public.whatsapp_hooks for insert with check (private.has_permission(tenant_id, 'settings', 'edit'));
