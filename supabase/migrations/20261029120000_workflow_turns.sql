-- Round robin inside a workflow step (e.g. Create Zoom meeting → who takes it): a counter per step
create table if not exists public.workflow_turns (
  workflow_id uuid not null references public.workflows(id) on delete cascade,
  node_id     text not null,
  n           int not null default 0,
  primary key (workflow_id, node_id)
);
alter table public.workflow_turns enable row level security;
revoke all on public.workflow_turns from anon, authenticated;

create or replace function public.workflow_next_turn(p_workflow uuid, p_node text)
returns int language sql security definer set search_path = '' as $$
  insert into public.workflow_turns (workflow_id, node_id, n) values (p_workflow, p_node, 1)
  on conflict (workflow_id, node_id) do update set n = public.workflow_turns.n + 1
  returning n
$$;
revoke all on function public.workflow_next_turn(uuid, text) from public, anon, authenticated;
grant execute on function public.workflow_next_turn(uuid, text) to service_role;
