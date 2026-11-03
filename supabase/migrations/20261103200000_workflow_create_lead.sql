-- Get lead details with "add the lead if not found" (e.g. a Booking Calendar booking from someone not yet a lead):
-- the workflow runner adds the lead to the workflow's funnel, like a form post would.
create or replace function public.workflow_create_lead(p_funnel uuid, p_data jsonb, p_note text default null)
returns uuid
language plpgsql
security definer
set search_path to ''
as $$
declare r jsonb; lid uuid;
begin
  r := private.ingest_lead(null, p_funnel, null, null, p_data, 'webhook', true, null);
  lid := (r ->> 'lead_id')::uuid;
  -- say where it came from instead of "Submitted the form on a form"
  if p_note is not null and r ->> 'status' = 'created' then
    update public.lead_activities set note = p_note
     where id = (select id from public.lead_activities where lead_id = lid order by created_at desc limit 1);
  end if;
  return lid;
end $$;
revoke all on function public.workflow_create_lead(uuid, jsonb, text) from public, anon, authenticated;
grant execute on function public.workflow_create_lead(uuid, jsonb, text) to service_role;
