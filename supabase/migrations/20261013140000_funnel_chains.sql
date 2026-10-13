-- ============================================================
-- Communication chain per funnel (n8n-style canvas in the Funnel → Chain tab).
-- nodes / edges are the canvas as saved: [{id, type, position:{x,y}, data:{…}}], [{id, source, target, sourceHandle}]
-- Node types: trigger (form submitted), whatsapp, email, call, wait, wait_event, condition (yes / no).
-- Nothing is sent yet: WhatsApp / email / call providers are connected later; is_active is only stored.
-- ============================================================
create table public.funnel_chains (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null,
  funnel_id   uuid not null unique,
  name        text not null default 'Communication chain',
  is_active   boolean not null default false,
  nodes       jsonb not null default '[]',
  edges       jsonb not null default '[]',
  updated_by  uuid references public.tenant_members (id) on delete set null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  foreign key (funnel_id, tenant_id) references public.funnels (id, tenant_id) on delete cascade
);
create trigger funnel_chains_set_updated_at before update on public.funnel_chains
  for each row execute function public.set_updated_at();

alter table public.funnel_chains enable row level security;
create policy "funnel_chains: read" on public.funnel_chains for select to authenticated
  using (exists (select 1 from public.funnels f where f.id = funnel_id
                 and (private.can_access_business(f.business_id) or private.has_permission(f.tenant_id, 'funnels', 'view'))));
create policy "funnel_chains: insert" on public.funnel_chains for insert to authenticated
  with check (private.has_permission(tenant_id, 'funnels', 'edit'));
create policy "funnel_chains: update" on public.funnel_chains for update to authenticated
  using (private.has_permission(tenant_id, 'funnels', 'edit'))
  with check (private.has_permission(tenant_id, 'funnels', 'edit'));
grant select, insert, update on public.funnel_chains to authenticated;
revoke all on public.funnel_chains from anon;
