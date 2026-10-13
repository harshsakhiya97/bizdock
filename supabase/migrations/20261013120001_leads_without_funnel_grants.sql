revoke execute on all functions in schema private from public, anon;
grant execute on all functions in schema private to authenticated;
revoke execute on function private.ingest_lead(uuid, uuid, uuid, jsonb, text, boolean, uuid) from authenticated;
revoke execute on function public.webhook_submit(text, jsonb) from public, anon, authenticated;
grant execute on function public.webhook_submit(text, jsonb) to service_role;
revoke execute on function public.import_leads(uuid, uuid, uuid, boolean, jsonb) from public, anon;
grant execute on function public.import_leads(uuid, uuid, uuid, boolean, jsonb) to authenticated;
revoke execute on function private.ingest_lead(uuid, uuid, jsonb, text, boolean, uuid) from authenticated;
revoke execute on function public.import_leads(uuid, uuid, boolean, jsonb) from public, anon, authenticated;
