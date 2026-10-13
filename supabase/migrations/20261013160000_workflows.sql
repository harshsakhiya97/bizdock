-- ============================================================
-- Workflows (sidebar → Workflows): any number per workspace, each started by a trigger:
--   form_submitted  a funnel's landing page form is submitted (optionally only some pages)
--   lead_added      a lead is added (by hand, import or any way), optionally in one funnel
--   stage_changed   a lead moves into a stage of a funnel
--   tag_added       a tag is added to a lead
--   before_event    X time before a webinar / event starts
--   after_event     X time after a webinar / event ends
-- The canvas (nodes / edges) holds the trigger box and the steps; trigger_type / funnel_id / event_id
-- are copied from the trigger box on save for listing and, later, for running.
-- Replaces funnel_chains (one per funnel), which stays unused.
-- Permission module: workflows (view / add / edit / delete).
-- ============================================================
create table public.workflows (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenants (id) on delete cascade,
  name          text not null default 'Workflow',
  is_active     boolean not null default false,
  trigger_type  text not null default 'form_submitted'
                check (trigger_type in ('form_submitted', 'lead_added', 'stage_changed', 'tag_added', 'before_event', 'after_event')),
  funnel_id     uuid references public.funnels (id) on delete set null,
  event_id      uuid references public.events (id) on delete set null,
  nodes         jsonb not null default '[]',
  edges         jsonb not null default '[]',
  updated_by    uuid references public.tenant_members (id) on delete set null,
  archived_at   timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index workflows_tenant_idx on public.workflows (tenant_id, created_at desc);
create trigger workflows_set_updated_at before update on public.workflows
  for each row execute function public.set_updated_at();

alter table public.workflows enable row level security;
create policy "workflows: read" on public.workflows for select to authenticated
  using (private.has_permission(tenant_id, 'workflows', 'view'));
create policy "workflows: insert" on public.workflows for insert to authenticated
  with check (private.has_permission(tenant_id, 'workflows', 'add'));
create policy "workflows: update" on public.workflows for update to authenticated
  using (private.has_permission(tenant_id, 'workflows', 'edit') or private.has_permission(tenant_id, 'workflows', 'delete'))
  with check (private.has_permission(tenant_id, 'workflows', 'edit') or private.has_permission(tenant_id, 'workflows', 'delete'));
grant select, insert, update on public.workflows to authenticated;
revoke all on public.workflows from anon;

-- the funnel automations saved so far become workflows started by "form submitted" on that funnel
insert into public.workflows (tenant_id, name, is_active, trigger_type, funnel_id, nodes, edges, updated_by, created_at)
select c.tenant_id, c.name, c.is_active, 'form_submitted', c.funnel_id,
       (select jsonb_agg(case when n ->> 'type' = 'trigger'
                              then jsonb_set(n, '{data}', jsonb_build_object('event', 'form_submitted', 'funnel_id', c.funnel_id, 'pages', coalesce(n -> 'data' -> 'pages', '[]')))
                              else n end)
        from jsonb_array_elements(c.nodes) n),
       c.edges, c.updated_by, c.created_at
from public.funnel_chains c;

-- Business Manager roles get workflows like funnels (applied with execute_sql):
-- update roles set permissions = permissions || '{"workflows":{"view":true,"add":true,"edit":true}}' where name = 'Business Manager';
