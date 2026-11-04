-- due runs are picked up every 10 seconds (was every minute): a message due at 4:01:04 goes at ~4:01:10,
-- not with the next one at the next minute
select cron.unschedule('workflow-runner');
select cron.schedule('workflow-runner', '10 seconds', $job$
  update public.workflow_runs set status = 'queued' where status = 'running' and updated_at < now() - interval '10 minutes';
  select private.kick_workflow_runner()
  where exists (select 1 from public.workflow_runs where status in ('queued', 'waiting') and next_at <= now());
$job$);
