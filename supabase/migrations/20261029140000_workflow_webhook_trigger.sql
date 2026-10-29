-- "On webhook call" workflows: a workflow of its own webhook URL (not tied to a funnel). A post starts a run
-- with the post's fields as variables; nothing is saved on leads. Same URL as the funnel webhooks
-- (lead-webhook?key=…), told apart by the key. Test mode keeps the next post as a sample to pick fields from.

alter table public.workflows drop constraint if exists workflows_trigger_type_check;
alter table public.workflows add constraint workflows_trigger_type_check
  check (trigger_type in ('form_submitted', 'lead_added', 'stage_changed', 'tag_added', 'before_event', 'after_event', 'webhook_call'));

create table public.workflow_hooks (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references public.tenants(id) on delete cascade,
  workflow_id      uuid not null unique references public.workflows(id) on delete cascade,
  webhook_key      text not null unique default replace(gen_random_uuid()::text, '-', ''),
  -- post field → variable name (only these are kept; empty = every field)
  field_map        jsonb not null default '{}'::jsonb,
  test_mode_until  timestamptz,
  sample           jsonb,
  sample_at        timestamptz,
  created_at       timestamptz not null default now()
);
alter table public.workflow_hooks enable row level security;
create policy "workflow_hooks: read" on public.workflow_hooks for select to authenticated
  using (private.has_permission(tenant_id, 'workflows', 'view'));
create policy "workflow_hooks: write" on public.workflow_hooks for update to authenticated
  using (private.has_permission(tenant_id, 'workflows', 'edit'))
  with check (private.has_permission(tenant_id, 'workflows', 'edit'));
grant select, update on public.workflow_hooks to authenticated;
revoke all on public.workflow_hooks from anon;

-- the run carries the post's fields (as variables)
alter table public.workflow_runs add column if not exists payload jsonb;

-- the workflow's webhook (made the first time it's asked for)
create or replace function public.workflow_hook_ensure(p_workflow uuid)
returns public.workflow_hooks language plpgsql security definer set search_path = '' as $$
declare w public.workflows; h public.workflow_hooks;
begin
  select * into w from public.workflows where id = p_workflow;
  if w.id is null then raise exception 'Workflow not found.'; end if;
  if not private.has_permission(w.tenant_id, 'workflows', 'view') then raise exception 'Not allowed.'; end if;
  select * into h from public.workflow_hooks where workflow_id = p_workflow;
  if h.id is null then
    if not private.has_permission(w.tenant_id, 'workflows', 'edit') then raise exception 'Not allowed.'; end if;
    insert into public.workflow_hooks (tenant_id, workflow_id) values (w.tenant_id, w.id) returning * into h;
  end if;
  return h;
end $$;
grant execute on function public.workflow_hook_ensure(uuid) to authenticated;

-- a new URL (the old one stops working)
create or replace function public.workflow_hook_regenerate(p_workflow uuid)
returns text language plpgsql security definer set search_path = '' as $$
declare k text;
begin
  update public.workflow_hooks h set webhook_key = replace(gen_random_uuid()::text, '-', '')
  where h.workflow_id = p_workflow and private.has_permission(h.tenant_id, 'workflows', 'edit')
  returning webhook_key into k;
  if k is null then raise exception 'Not allowed.'; end if;
  return k;
end $$;
grant execute on function public.workflow_hook_regenerate(uuid) to authenticated;

-- a post to a workflow webhook
create or replace function private.workflow_hook_submit(h public.workflow_hooks, p_data jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  w public.workflows;
  d jsonb := coalesce(p_data, '{}') - 'key' - '_redirect' - 'redirect';
  v jsonb;
  rid uuid;
begin
  if h.test_mode_until is not null and h.test_mode_until > now() then
    update public.workflow_hooks set sample = d, sample_at = now(), test_mode_until = null where id = h.id;
    return jsonb_build_object('status', 'test', 'message', 'Test received. Pick the fields in the workflow.');
  end if;
  select * into w from public.workflows where id = h.workflow_id;
  if w.id is null or w.archived_at is not null or not w.is_active or w.trigger_type <> 'webhook_call' then
    raise exception 'This workflow is switched off.';
  end if;
  -- the picked fields under their variable names (none picked: every field)
  if h.field_map = '{}'::jsonb then
    v := d;
  else
    v := coalesce((select jsonb_object_agg(m.value #>> '{}', d -> m.key) from jsonb_each(h.field_map) m
                   where d ? m.key and coalesce(m.value #>> '{}', '') <> ''), '{}');
  end if;
  insert into public.workflow_runs (tenant_id, workflow_id, payload) values (w.tenant_id, w.id, v) returning id into rid;
  begin
    perform private.kick_workflow_runner();
  exception when others then null;
  end;
  return jsonb_build_object('status', 'started', 'run_id', rid);
end $$;

-- webhook_submit: a workflow webhook's key goes to the workflow
do $$
declare src text; a int;
begin
  src := pg_get_functiondef('public.webhook_submit(text,jsonb)'::regprocedure);
  a := position('  select wh.* into w from public.funnel_webhooks wh' in src);
  if a = 0 then raise exception 'webhook_submit: start not found'; end if;
  src := substr(src, 1, a - 1) || $x$  if exists (select 1 from public.workflow_hooks where webhook_key = p_key) then
    return private.workflow_hook_submit((select x from public.workflow_hooks x where x.webhook_key = p_key), p_data);
  end if;
$x$ || substr(src, a);
  execute src;
end $$;

-- a re-run keeps the post's fields
create or replace function public.workflow_rerun(p_run uuid)
returns uuid language plpgsql security definer set search_path = '' as $$
declare r public.workflow_runs; v_run uuid;
begin
  select * into r from public.workflow_runs where id = p_run;
  if r.id is null then raise exception 'This run doesn''t exist any more.'; end if;
  if not exists (select 1 from public.workflows w where w.id = r.workflow_id and w.archived_at is null) then
    raise exception 'This workflow doesn''t exist any more.';
  end if;
  if not private.has_permission(r.tenant_id, 'workflows', 'edit') then raise exception 'You can''t run this workflow.'; end if;
  insert into public.workflow_runs (tenant_id, workflow_id, lead_id, is_test, test_data, payload)
  values (r.tenant_id, r.workflow_id, r.lead_id, r.is_test, r.test_data, r.payload)
  returning id into v_run;
  begin
    perform private.kick_workflow_runner();
  exception when others then null;
  end;
  return v_run;
end $$;

revoke execute on all functions in schema private from public, anon;
grant execute on all functions in schema private to authenticated;
