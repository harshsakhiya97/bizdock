-- Test run: start a workflow by hand with typed-in lead details (no lead is created; works while the workflow is off)
alter table public.workflow_runs add column if not exists is_test boolean not null default false;
alter table public.workflow_runs add column if not exists test_data jsonb;

create or replace function public.workflow_test_run(p_workflow uuid, p_data jsonb)
returns uuid language plpgsql security definer set search_path = ''
as $$
declare v_tenant uuid; v_run uuid;
begin
  select tenant_id into v_tenant from public.workflows where id = p_workflow and archived_at is null;
  if v_tenant is null then raise exception 'This workflow doesn''t exist any more.'; end if;
  if not private.has_permission(v_tenant, 'workflows', 'edit') then raise exception 'You can''t run this workflow.'; end if;
  if coalesce(trim(p_data ->> 'phone'), '') = '' then raise exception 'Enter a phone number.'; end if;
  insert into public.workflow_runs (tenant_id, workflow_id, is_test, test_data)
  values (v_tenant, p_workflow, true, p_data)
  returning id into v_run;
  begin
    perform private.kick_workflow_runner();
  exception when others then null;
  end;
  return v_run;
end $$;
revoke all on function public.workflow_test_run(uuid, jsonb) from public, anon;
grant execute on function public.workflow_test_run(uuid, jsonb) to authenticated;
