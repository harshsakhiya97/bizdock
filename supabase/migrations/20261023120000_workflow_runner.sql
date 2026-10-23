-- Workflow runner (first version): a form submission starts every active "Form submitted" workflow
-- of its funnel; the workflow-runner function walks the steps (WhatsApp template via WATI, Wait).
create table if not exists public.workflow_runs (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  workflow_id uuid not null references public.workflows(id) on delete cascade,
  lead_id uuid references public.leads(id) on delete cascade,
  submission_id uuid references public.lead_submissions(id) on delete set null,
  status text not null default 'queued' check (status in ('queued', 'waiting', 'running', 'done', 'failed', 'stopped')),
  node_id text not null default 'trigger',          -- the box the run is at (its next step comes after it)
  next_at timestamptz not null default now(),        -- when the run continues (Wait steps)
  log jsonb not null default '[]'::jsonb,            -- [{ at, node_id, kind, status, detail }]
  error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (workflow_id, submission_id)
);
create index if not exists workflow_runs_due on public.workflow_runs (next_at) where status in ('queued', 'waiting');
create index if not exists workflow_runs_workflow on public.workflow_runs (workflow_id, created_at desc);

alter table public.workflow_runs enable row level security;
create policy "workflow_runs: read" on public.workflow_runs for select to authenticated
  using (private.has_permission(tenant_id, 'workflows', 'view'));
grant select on public.workflow_runs to authenticated;

-- shared secret between the database (cron + new submissions) and the runner function
select vault.create_secret(replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''), 'workflow_cron_secret', 'workflow-runner calls');
create or replace function public.workflow_cron_secret()
returns text language sql security definer set search_path = ''
as $$ select decrypted_secret from vault.decrypted_secrets where name = 'workflow_cron_secret' limit 1 $$;
revoke all on function public.workflow_cron_secret() from public, anon, authenticated;
grant execute on function public.workflow_cron_secret() to service_role;

create or replace function private.kick_workflow_runner()
returns void language sql security definer set search_path = ''
as $$
  select net.http_post(
    url := 'https://tnnjudehqalkgglzkfik.supabase.co/functions/v1/workflow-runner',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-secret', public.workflow_cron_secret()),
    body := '{"action":"cron"}'::jsonb,
    timeout_milliseconds := 55000
  );
$$;

-- a submission → one run per matching active workflow, then wake the runner straight away
create or replace function private.start_form_workflows()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare v_count int;
begin
  if new.lead_id is null or new.funnel_id is null then return new; end if;
  insert into public.workflow_runs (tenant_id, workflow_id, lead_id, submission_id)
  select new.tenant_id, w.id, new.lead_id, new.id
  from public.workflows w
  where w.tenant_id = new.tenant_id
    and w.is_active and w.archived_at is null
    and w.trigger_type = 'form_submitted'
    and w.funnel_id = new.funnel_id
    and (
      coalesce(jsonb_array_length((select n.value -> 'data' -> 'pages' from jsonb_array_elements(w.nodes) n where n.value ->> 'id' = 'trigger' limit 1)), 0) = 0
      or (new.webhook_id is not null and exists (
            select 1 from jsonb_array_elements(w.nodes) n, jsonb_array_elements_text(n.value -> 'data' -> 'pages') p
            where n.value ->> 'id' = 'trigger' and p = new.webhook_id::text))
    )
  on conflict (workflow_id, submission_id) do nothing;
  get diagnostics v_count = row_count;
  if v_count > 0 then
    begin
      perform private.kick_workflow_runner();
    exception when others then null;  -- the minute cron picks it up anyway
    end;
  end if;
  return new;
end $$;

drop trigger if exists lead_submissions_start_workflows on public.lead_submissions;
create trigger lead_submissions_start_workflows after insert on public.lead_submissions
  for each row execute function private.start_form_workflows();

-- the runner takes due runs one batch at a time (no run is taken twice)
create or replace function public.workflow_claim_runs(p_limit int default 25)
returns setof public.workflow_runs language sql security definer set search_path = ''
as $$
  update public.workflow_runs r set status = 'running', updated_at = now()
  where r.id in (
    select id from public.workflow_runs
    where status in ('queued', 'waiting') and next_at <= now()
    order by next_at limit p_limit
    for update skip locked)
  returning r.*;
$$;
revoke all on function public.workflow_claim_runs(int) from public, anon, authenticated;
grant execute on function public.workflow_claim_runs(int) to service_role;

-- runs left "running" by a crash go back in the queue after 10 minutes; due runs every minute
select cron.schedule('workflow-runner', '* * * * *', $job$
  update public.workflow_runs set status = 'queued' where status = 'running' and updated_at < now() - interval '10 minutes';
  select private.kick_workflow_runner()
  where exists (select 1 from public.workflow_runs where status in ('queued', 'waiting') and next_at <= now());
$job$);
