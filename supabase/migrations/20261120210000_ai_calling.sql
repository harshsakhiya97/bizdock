-- AI Calling (HelloRix voice API): System Connections → AI Calling (API key, caller number, voice, persona, insights,
-- calling hours, fixed opening). The hellorix function places calls with a template (a HelloRix "objective"), takes the
-- result from HelloRix's webhook (or checks every 5 minutes) and keeps each call here with its cost in ₹.
-- Side menu → AI Calling: Individual call · Call history · Templates. Leads: Call from AI + AI Calls tab. Workflows: AI call.

alter table public.integrations drop constraint if exists integrations_provider_check;
alter table public.integrations add constraint integrations_provider_check
  check (provider = any (array['whatsapp','callyzer','zoom','voice_call','perisclaw','facebook_ads','razorpay','google_ads','gemini','hellorix']));

create table if not exists public.ai_calls (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  integration_id uuid references public.integrations(id) on delete set null,
  lead_id uuid references public.leads(id) on delete set null,
  business_id uuid references public.businesses(id) on delete set null,
  member_id uuid references public.tenant_members(id) on delete set null,   -- who placed it (null: a workflow)
  workflow_run_id uuid references public.workflow_runs(id) on delete set null,
  via text not null default 'manual' check (via in ('manual', 'lead', 'workflow')),
  to_phone text not null,
  to_name text,
  objective_id text,                       -- HelloRix template
  objective_name text,
  hx_call_id text,                         -- HelloRix call id (null while queued)
  hx_queue_id text,
  status text not null default 'queued',   -- queued / ringing / in_progress / completed / no_answer / busy / failed / cancelled / expired
  final boolean not null default false,
  outcome text,                            -- interested / callback / declined / deferred / no_answer / busy / failed
  summary text,
  collected jsonb not null default '{}'::jsonb,
  recording_url text,
  duration_seconds int,
  talk_seconds int,
  cost numeric(12, 2),                     -- ₹
  cost_final boolean not null default false,
  hangup_party text,
  error text,
  placed_at timestamptz not null default now(),
  answered_at timestamptz,
  ended_at timestamptz,
  lead_updated boolean not null default false,
  raw jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists ai_calls_tenant_time on public.ai_calls (tenant_id, placed_at desc);
create index if not exists ai_calls_lead on public.ai_calls (lead_id);
create unique index if not exists ai_calls_hx on public.ai_calls (tenant_id, hx_call_id) where hx_call_id is not null;
create index if not exists ai_calls_open on public.ai_calls (tenant_id) where not final;

alter table public.ai_calls enable row level security;
-- whose calls: All / Team / Own (AI Calling → Call history), and every call of a lead they can open
drop policy if exists "ai_calls: read" on public.ai_calls;
create policy "ai_calls: read" on public.ai_calls for select to authenticated using (
  private.is_member(tenant_id) and (
    case private.area_scope(tenant_id, 'ai_calls')
      when 'all' then true
      when 'team' then member_id is null or member_id in (select private.my_team(tenant_id))
      when 'own' then member_id = private.my_member_id(tenant_id)
      else false
    end
    or (lead_id is not null and exists (select 1 from public.leads l where l.id = ai_calls.lead_id))
  )
);
grant select on public.ai_calls to authenticated;

-- every 5 minutes while a call has no final result: ask HelloRix (the webhook usually comes first)
create or replace function private.kick_hellorix() returns void
language sql security definer set search_path = '' as $$
  select net.http_post(
    url := 'https://tnnjudehqalkgglzkfik.supabase.co/functions/v1/hellorix',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-secret', public.workflow_cron_secret()),
    body := '{"action":"cron"}'::jsonb,
    timeout_milliseconds := 60000
  );
$$;
do $$
begin
  perform cron.unschedule('hellorix-sync') where exists (select 1 from cron.job where jobname = 'hellorix-sync');
  perform cron.schedule('hellorix-sync', '*/5 * * * *', $c$
    select private.kick_hellorix() where exists (select 1 from public.ai_calls where not final and placed_at > now() - interval '2 days');
  $c$);
end $$;

-- the workflow step "AI call" waits for its call: wake the runs waiting on a call that just got its result
create or replace function private.ai_call_done() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.final and not old.final and new.workflow_run_id is not null then
    update public.workflow_runs set next_at = now() where id = new.workflow_run_id and status = 'waiting';
  end if;
  return new;
end $$;
drop trigger if exists ai_calls_done on public.ai_calls;
create trigger ai_calls_done after update of final on public.ai_calls for each row execute function private.ai_call_done();

-- permissions: AI Calling for whoever can add leads today (owners have everything anyway)
update public.roles set permissions = permissions
  || jsonb_build_object('ai_calling', jsonb_build_object('view', coalesce((permissions #>> '{leads,add}')::boolean, false), 'templates', false))
  || jsonb_build_object('scope', coalesce(permissions -> 'scope', '{}'::jsonb) || jsonb_build_object('ai_calls', case when coalesce((permissions #>> '{leads,add}')::boolean, false) then 'own' else 'none' end))
 where permissions is not null and not (permissions ? 'ai_calling');

-- the hellorix function asks: may the caller use AI Calling (place calls / manage templates), are they in the workspace
create or replace function public.ai_calling_can(p_tenant uuid, p_action text) returns boolean
language sql stable security definer set search_path = '' as $$
  select case p_action when 'member' then private.is_member(p_tenant) else private.has_permission(p_tenant, 'ai_calling', p_action) end
$$;
revoke all on function public.ai_calling_can(uuid, text) from public, anon;
grant execute on function public.ai_calling_can(uuid, text) to authenticated;
