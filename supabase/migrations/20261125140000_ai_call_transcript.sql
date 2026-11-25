-- AI calls: the transcript is kept (saved when the call ends), and when the lead was updated after the call
-- (category, note, transcript, AI Insights) for the AI call step's "Received & lead updated" path.
-- AI Insights read AI calls too: a saved transcript marks the lead's summary for an update.
alter table public.ai_calls add column if not exists transcript jsonb;
alter table public.ai_calls add column if not exists lead_synced_at timestamptz;

create or replace function private.lead_insight_on_ai_call() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.lead_id is not null and new.transcript is not null and new.transcript is distinct from old.transcript then
    perform private.lead_insight_touch(new.lead_id, new.tenant_id);
  end if;
  return null;
end $$;
drop trigger if exists lead_insight_touch on public.ai_calls;
create trigger lead_insight_touch after update of transcript on public.ai_calls
  for each row execute function private.lead_insight_on_ai_call();
