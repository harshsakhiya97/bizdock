-- Call transcripts a little at a time: once an hour, up to 15 calls (Gemini's daily limit on the workspace's key).
create or replace function private.kick_call_transcribe() returns void
language sql security definer set search_path = '' as $$
  select net.http_post(
    url := 'https://tnnjudehqalkgglzkfik.supabase.co/functions/v1/call-transcribe',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-secret', public.workflow_cron_secret()),
    body := '{"action":"cron","max":15}'::jsonb,
    timeout_milliseconds := 60000
  );
$$;
select cron.alter_job((select jobid from cron.job where jobname = 'call-transcribe'), schedule := '7 * * * *');
