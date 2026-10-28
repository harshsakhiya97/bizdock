-- Re-run: start a workflow again from its first step for the same lead (or the same test details).
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
  insert into public.workflow_runs (tenant_id, workflow_id, lead_id, is_test, test_data)
  values (r.tenant_id, r.workflow_id, r.lead_id, r.is_test, r.test_data)
  returning id into v_run;
  begin
    perform private.kick_workflow_runner();
  exception when others then null;
  end;
  return v_run;
end $$;
revoke all on function public.workflow_rerun(uuid) from public, anon;
grant execute on function public.workflow_rerun(uuid) to authenticated;
