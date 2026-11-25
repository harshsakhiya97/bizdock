-- WATI's webhook in batches: each status update (template sent / delivered / read / failed) is only noted here on
-- arrival (one quick insert, WATI gets its OK at once); every minute the wati-webhook function works through them in
-- order and updates WhatsApp logs, and saves the workspace's "last event received" once. A burst of ~700 updates in a
-- minute (25 Nov) had each one update the same whatsapp_hooks row and find its log, and jammed the API.
-- Customer replies still go in at once (few, and the team wants them straight away).
create table if not exists public.wati_events (
  id bigserial primary key,
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  payload jsonb not null,
  received_at timestamptz not null default now(),
  processed_at timestamptz,
  tries int not null default 0,
  error text
);
create index if not exists wati_events_todo on public.wati_events (id) where processed_at is null;
create index if not exists wati_events_done on public.wati_events (processed_at) where processed_at is not null;
alter table public.wati_events enable row level security;
-- no policies: only the server (service role) reads and writes it

create or replace function private.kick_wati_events() returns void
language sql security definer set search_path = '' as $$
  select net.http_post(
    url := 'https://tnnjudehqalkgglzkfik.supabase.co/functions/v1/wati-webhook',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-secret', public.workflow_cron_secret()),
    body := '{"action":"process"}'::jsonb,
    timeout_milliseconds := 60000
  );
$$;
do $$
begin
  perform cron.unschedule('wati-events') where exists (select 1 from cron.job where jobname = 'wati-events');
  perform cron.schedule('wati-events', '* * * * *', $c$
    select private.kick_wati_events() where exists (select 1 from public.wati_events where processed_at is null and tries < 5);
    delete from public.wati_events where processed_at < now() - interval '7 days';
  $c$);
end $$;
