-- Lead page: AI summary of each lead (Gemini, System Connections → Gemini AI) and the "At a glance" numbers.
--   lead_insights: one row per lead — the summary (content), when it was written, and stale = something changed since.
--   Any change to the lead (added / edited, follow-up, call transcript, meeting, booking, payment, WhatsApp, note) marks
--   it stale; the worker (edge function lead-insight, every minute) rewrites it once the lead has been quiet for a
--   minute, so many edits in a row give one rewrite.
--   lead_insight_syncs: Leads → Summarize leads (the leads with no summary yet, in the background).

create table if not exists public.lead_insights (
  lead_id uuid primary key references public.leads(id) on delete cascade,
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  content jsonb,
  model text,
  generated_at timestamptz,
  stale boolean not null default true,
  stale_at timestamptz not null default now(),
  lease timestamptz,
  tries int not null default 0,
  error text
);
create index if not exists lead_insights_stale on public.lead_insights (stale_at) where stale;
create index if not exists lead_insights_tenant on public.lead_insights (tenant_id);
alter table public.lead_insights enable row level security;
drop policy if exists lead_insights_read on public.lead_insights;
create policy lead_insights_read on public.lead_insights for select to authenticated
  using (exists (select 1 from public.leads l where l.id = lead_id));
grant select on public.lead_insights to authenticated;

create table if not exists public.lead_insight_syncs (
  tenant_id uuid primary key references public.tenants(id) on delete cascade,
  active boolean not null default false,
  started_at timestamptz,
  started_by uuid,
  finished_at timestamptz,
  total int not null default 0,
  note text
);
alter table public.lead_insight_syncs enable row level security;

-- the workspace has Gemini connected
create or replace function private.has_gemini(t uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.integrations where tenant_id = t and provider = 'gemini' and is_enabled and coalesce(config->>'api_key', '') <> '')
$$;

-- mark one lead's summary for a rewrite (never stops the change itself)
create or replace function private.lead_insight_touch(p_lead uuid, p_tenant uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if p_lead is null or p_tenant is null then return; end if;
  insert into public.lead_insights (lead_id, tenant_id, stale, stale_at)
  values (p_lead, p_tenant, true, now())
  on conflict (lead_id) do update set stale = true, stale_at = now(), tries = 0, error = null;
exception when others then null;
end $$;

-- leads: added, or anything changed (not just the follow-up date the app keeps in step)
create or replace function private.lead_insight_on_lead() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'UPDATE' and (to_jsonb(old) - 'updated_at' - 'next_follow_up_at') = (to_jsonb(new) - 'updated_at' - 'next_follow_up_at') then
    return null;
  end if;
  perform private.lead_insight_touch(new.id, new.tenant_id);
  return null;
end $$;
drop trigger if exists lead_insight_touch on public.leads;
create trigger lead_insight_touch after insert or update on public.leads
  for each row execute function private.lead_insight_on_lead();

-- follow-ups, meetings, bookings: added or changed
create or replace function private.lead_insight_on_row() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'UPDATE' and to_jsonb(old) - 'updated_at' = to_jsonb(new) - 'updated_at' then return null; end if;
  perform private.lead_insight_touch(new.lead_id, new.tenant_id);
  if tg_op = 'UPDATE' and old.lead_id is distinct from new.lead_id then perform private.lead_insight_touch(old.lead_id, old.tenant_id); end if;
  return null;
end $$;
drop trigger if exists lead_insight_touch on public.follow_ups;
create trigger lead_insight_touch after insert or update on public.follow_ups
  for each row execute function private.lead_insight_on_row();
drop trigger if exists lead_insight_touch on public.meetings;
create trigger lead_insight_touch after insert or update on public.meetings
  for each row execute function private.lead_insight_on_row();
drop trigger if exists lead_insight_touch on public.bookings;
create trigger lead_insight_touch after insert or update on public.bookings
  for each row execute function private.lead_insight_on_row();

-- calls: a transcript is written, or the call is linked to the lead
create or replace function private.lead_insight_on_call() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' or (new.transcript_status = 'done' and new.transcript is distinct from old.transcript)
     or new.lead_id is distinct from old.lead_id then
    perform private.lead_insight_touch(new.lead_id, new.tenant_id);
  end if;
  return null;
end $$;
drop trigger if exists lead_insight_touch on public.calls;
create trigger lead_insight_touch after insert or update of transcript, transcript_status, lead_id on public.calls
  for each row execute function private.lead_insight_on_call();

-- invoice payments: on the invoice's lead
create or replace function private.lead_insight_on_payment() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform private.lead_insight_touch(i.lead_id, i.tenant_id) from public.invoices i where i.id = new.invoice_id;
  return null;
end $$;
drop trigger if exists lead_insight_touch on public.invoice_payments;
create trigger lead_insight_touch after insert or update on public.invoice_payments
  for each row execute function private.lead_insight_on_payment();

-- WhatsApp messages and notes: added
create or replace function private.lead_insight_on_add() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform private.lead_insight_touch(new.lead_id, new.tenant_id);
  return null;
end $$;
drop trigger if exists lead_insight_touch on public.whatsapp_logs;
create trigger lead_insight_touch after insert on public.whatsapp_logs
  for each row execute function private.lead_insight_on_add();
drop trigger if exists lead_insight_touch on public.lead_activities;
create trigger lead_insight_touch after insert on public.lead_activities
  for each row when (new.kind in ('note', 'stage', 'temperature')) execute function private.lead_insight_on_add();

-- Leads → Summarize leads: how many leads have no summary, and the sync
create or replace function public.lead_insight_status(p_tenant uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select case when private.has_permission(p_tenant, 'leads', 'view') then
    jsonb_build_object(
      'missing', (select count(*) from public.leads l
                   where l.tenant_id = p_tenant and not coalesce(l.is_archived, false)
                     and not exists (select 1 from public.lead_insights i where i.lead_id = l.id and (i.content is not null or i.tries >= 3))),
      'done', (select count(*) from public.lead_insights i join public.leads l on l.id = i.lead_id
                where i.tenant_id = p_tenant and i.content is not null and not coalesce(l.is_archived, false)),
      'failed', (select count(*) from public.lead_insights i where i.tenant_id = p_tenant and i.content is null and i.tries >= 3),
      'gemini', private.has_gemini(p_tenant),
      'sync', (select to_jsonb(s) - 'tenant_id' from public.lead_insight_syncs s where s.tenant_id = p_tenant)
    )
  end
$$;
revoke all on function public.lead_insight_status(uuid) from public, anon;
grant execute on function public.lead_insight_status(uuid) to authenticated;

create or replace function public.lead_insight_sync_set(p_tenant uuid, p_on boolean) returns void
language plpgsql volatile security definer set search_path = '' as $$
begin
  if not (private.has_permission(p_tenant, 'leads', 'edit') or private.has_permission(p_tenant, 'settings', 'edit')) then
    raise exception 'Not allowed';
  end if;
  if p_on then
    insert into public.lead_insight_syncs (tenant_id, active, started_at, started_by, finished_at, total, note)
    values (p_tenant, true, now(), auth.uid(), null, (public.lead_insight_status(p_tenant)->>'missing')::int, null)
    on conflict (tenant_id) do update set active = true, started_at = now(), started_by = auth.uid(), finished_at = null,
      total = excluded.total, note = null;
  else
    update public.lead_insight_syncs set active = false, finished_at = now(), note = 'Stopped' where tenant_id = p_tenant;
  end if;
end $$;
revoke all on function public.lead_insight_sync_set(uuid, boolean) from public, anon;
grant execute on function public.lead_insight_sync_set(uuid, boolean) to authenticated;

-- the worker takes leads to write (2-minute lease):
--   'auto': changed leads quiet for a minute (workspaces with Gemini) · 'sync': p_tenant's leads with no summary
create or replace function public.lead_insight_claim(p_limit int, p_mode text, p_tenant uuid) returns setof uuid
language plpgsql volatile security definer set search_path = '' as $$
begin
  if p_mode = 'auto' then
    return query
    update public.lead_insights i set lease = now() + interval '2 minutes'
     where i.lead_id in (
       select x.lead_id from public.lead_insights x
        where x.stale and x.tries < 3 and x.stale_at < now() - interval '1 minute'
          and (x.lease is null or x.lease < now()) and private.has_gemini(x.tenant_id)
        order by x.stale_at
        limit p_limit
        for update skip locked)
    returning i.lead_id;
  else
    return query
    insert into public.lead_insights (lead_id, tenant_id, stale, stale_at, lease)
    select l.id, l.tenant_id, true, now(), now() + interval '2 minutes'
      from public.leads l
     where l.tenant_id = p_tenant and not coalesce(l.is_archived, false)
       and not exists (select 1 from public.lead_insights i
                        where i.lead_id = l.id and (i.content is not null or i.tries >= 3 or i.lease > now()))
     order by l.created_at desc
     limit p_limit
    on conflict (lead_id) do update set lease = excluded.lease
    returning lead_id;
  end if;
end $$;
revoke all on function public.lead_insight_claim(int, text, uuid) from public, anon, authenticated;
grant execute on function public.lead_insight_claim(int, text, uuid) to service_role;

-- Lead page → At a glance (the lead must be one the caller can see)
create or replace function public.lead_glance(p_lead uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  l public.leads;
begin
  select * into l from public.leads where id = p_lead;
  if l.id is null or not (private.can_see_lead(l.tenant_id, l.business_id, l.owner_id) and private.can_access_sub(l.business_id, l.sub_business_id)) then
    return null;
  end if;
  return jsonb_build_object(
    'category_since', (select max(a.created_at) from public.lead_activities a where a.lead_id = p_lead and a.kind = 'temperature'),
    'next_follow_up', (select jsonb_build_object('due_at', f.due_at, 'mode', f.mode, 'purpose', f.purpose)
                         from public.follow_ups f where f.lead_id = p_lead and f.status = 'pending' order by f.due_at limit 1),
    'overdue', (select count(*) from public.follow_ups f where f.lead_id = p_lead and f.status = 'pending' and f.due_at < now()),
    'last_follow_up', (select jsonb_build_object('at', f.completed_at, 'mode', f.mode, 'outcome', o.name, 'note', f.result_note)
                         from public.follow_ups f left join public.follow_up_outcomes o on o.id = f.outcome_id
                        where f.lead_id = p_lead and f.status = 'done' order by f.completed_at desc nulls last limit 1),
    'calls', (select jsonb_build_object('total', count(*), 'connected', count(*) filter (where c.outcome = 'Connected' or coalesce(c.duration_sec, 0) > 0))
                from public.calls c where c.lead_id = p_lead),
    'last_call', (select jsonb_build_object('at', c.started_at, 'direction', c.direction, 'duration', c.duration_sec, 'outcome', c.outcome, 'by', c.emp_name)
                    from public.calls c where c.lead_id = p_lead order by c.started_at desc nulls last limit 1),
    'next_meeting', (select jsonb_build_object('date', m.meeting_date, 'start', m.start_time, 'mode', m.mode, 'status', m.status)
                       from public.meetings m where m.lead_id = p_lead and m.meeting_date >= (now() at time zone 'Asia/Kolkata')::date
                        and coalesce(m.status, '') not in ('cancelled', 'canceled')
                       order by m.meeting_date, m.start_time limit 1),
    'last_meeting', (select jsonb_build_object('date', m.meeting_date, 'start', m.start_time, 'mode', m.mode, 'status', m.status)
                       from public.meetings m where m.lead_id = p_lead and m.meeting_date < (now() at time zone 'Asia/Kolkata')::date
                       order by m.meeting_date desc, m.start_time desc limit 1),
    'whatsapp', (select jsonb_build_object('at', w.sent_at, 'direction', w.direction, 'status', w.status, 'template', w.template)
                   from public.whatsapp_logs w where w.lead_id = p_lead order by w.sent_at desc nulls last limit 1)
  );
end $$;
revoke all on function public.lead_glance(uuid) from public, anon;
grant execute on function public.lead_glance(uuid) to authenticated;

-- the worker: every minute while a changed lead waits or a sync is on
select cron.unschedule('lead-insight') where exists (select 1 from cron.job where jobname = 'lead-insight');
create or replace function private.kick_lead_insight() returns void
language sql security definer set search_path = '' as $$
  select net.http_post(
    url := 'https://tnnjudehqalkgglzkfik.supabase.co/functions/v1/lead-insight',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-secret', public.workflow_cron_secret()),
    body := '{"action":"cron"}'::jsonb,
    timeout_milliseconds := 60000
  );
$$;
select cron.schedule('lead-insight', '* * * * *', $c$
  select private.kick_lead_insight()
  where exists (select 1 from public.lead_insight_syncs where active)
     or exists (select 1 from public.lead_insights x
                where x.stale and x.tries < 3 and x.stale_at < now() - interval '1 minute'
                  and (x.lease is null or x.lease < now()) and private.has_gemini(x.tenant_id));
$c$);
