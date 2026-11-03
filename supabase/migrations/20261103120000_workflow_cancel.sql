-- Runs list: cancel a run that hasn't finished (starting / waiting). It stops there; nothing after it runs.
create or replace function public.workflow_cancel(p_run uuid)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare r public.workflow_runs; v_who text;
begin
  select * into r from public.workflow_runs where id = p_run;
  if r.id is null then raise exception 'This run doesn''t exist any more.'; end if;
  if not private.has_permission(r.tenant_id, 'workflows', 'edit') then raise exception 'You can''t cancel this run.'; end if;
  if r.status = 'running' then raise exception 'This run is doing a step right now; try again in a moment.'; end if;
  if r.status not in ('queued', 'waiting') then raise exception 'This run has already finished.'; end if;
  select nullif(trim(p.full_name), '') into v_who from public.profiles p where p.id = auth.uid();
  update public.workflow_runs
     set status = 'stopped',
         error = 'Cancelled' || coalesce(' by ' || v_who, '') || '.',
         updated_at = now()
   where id = p_run and status in ('queued', 'waiting');
end $$;

revoke all on function public.workflow_cancel(uuid) from public, anon;
grant execute on function public.workflow_cancel(uuid) to authenticated;
