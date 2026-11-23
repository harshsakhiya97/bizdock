-- Call transcripts: the hourly background run is stopped (Harsh, 23 Nov 2026). Regenerate on a call still works.
-- To start it again: select cron.schedule('call-transcribe', '7 * * * *', $c$ select private.kick_call_transcribe() $c$);
select cron.unschedule('call-transcribe') where exists (select 1 from cron.job where jobname = 'call-transcribe');
