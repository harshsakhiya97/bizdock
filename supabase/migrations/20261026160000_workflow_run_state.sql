-- progress inside a step that runs over time (Bulk WhatsApp: which message is next)
alter table public.workflow_runs add column if not exists state jsonb not null default '{}'::jsonb;
