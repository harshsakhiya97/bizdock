-- Rewrite transcripts in the background (Team / Customer fix) while the old one stays visible: transcript_redo.
-- The hourly run takes the calls never written first, then those to rewrite.
alter table public.calls add column if not exists transcript_redo boolean not null default false;
update public.calls set transcript_redo = true where source = 'callyzer' and transcript_status = 'done';

create or replace function public.call_transcript_claim(p_limit integer default 5) returns setof uuid
language sql volatile security definer set search_path = '' as $$
  update public.calls set transcript_lease = now() + interval '3 minutes'
  where id in (
    select id from public.calls
    where source = 'callyzer' and recording_path is not null and coalesce(duration_sec, 0) >= 5
      and ((transcript_status is null or transcript_status = 'waiting') or (transcript_status = 'done' and transcript_redo and transcript_at < timestamptz '2026-11-21 15:00:00+00'))
      and transcript_tries < 3
      and (transcript_lease is null or transcript_lease < now())
    order by coalesce(transcript_status = 'done', false), started_at desc
    limit p_limit
    for update skip locked
  )
  returning id
$$;
revoke all on function public.call_transcript_claim(integer) from public, anon, authenticated;

select cron.alter_job((select jobid from cron.job where jobname = 'call-transcribe'), command := $c$
  select private.kick_call_transcribe()
  where exists (select 1 from public.calls
                where source = 'callyzer' and recording_path is not null and coalesce(duration_sec, 0) >= 5
                  and ((transcript_status is null or transcript_status = 'waiting') or (transcript_status = 'done' and transcript_redo and transcript_at < timestamptz '2026-11-21 15:00:00+00'))
                  and transcript_tries < 3
                  and (transcript_lease is null or transcript_lease < now()));
$c$);
