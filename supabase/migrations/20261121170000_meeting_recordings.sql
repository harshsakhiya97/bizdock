-- Meeting recordings: the Zoom cloud recording of each meeting / webinar date, copied into our own storage
-- (bucket meeting-recordings, private), with its transcript and an AI summary (Gemini); recordings can also be added
-- by hand (a file uploaded, or a link). Everyone who can see the meeting can see its recording.
--
-- Flow (edge function zoom):
--   1. find:  action 'rec_find' (cron, every 10 min) — meetings / webinar dates that ended 30 min – 3 days ago and
--             have no recording row yet: Zoom's recording list → one row (copy_status 'waiting'); also on Fetch attendance.
--   2. copy:  action 'rec_work' (cron, every minute while something waits) — the video (MP4) and the audio (M4A) are
--             streamed from Zoom into <tenant>/<yyyy>/<mm>/<id>-video.mp4 / -audio.m4a; Zoom's transcript (VTT) if any.
--   3. AI:    then the transcript (from the audio when Zoom has none) and the summary (Gemini, the workspace's key and
--             monthly limit); the summary is added as a note on the meeting's lead.

create table public.meeting_recordings (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  meeting_id uuid references public.meetings(id) on delete cascade,
  event_id uuid references public.events(id) on delete cascade,
  source text not null default 'zoom' check (source in ('zoom', 'manual')),
  title text,
  -- Zoom: the meeting instance and its files ({ id, file_type, recording_type, file_size, file_extension, download_url })
  zoom_uuid text,
  zoom_files jsonb not null default '[]'::jsonb,
  recorded_at timestamptz,
  duration_sec integer,
  -- our copies (bucket meeting-recordings), or a link added by hand
  video_path text,
  video_size bigint,
  audio_path text,
  audio_size bigint,
  link_url text,
  copy_status text not null default 'waiting' check (copy_status in ('waiting', 'done', 'error')),
  copy_tries integer not null default 0,
  copy_error text,
  -- transcript and summary
  transcript text,
  summary text,
  ai_status text not null default 'waiting' check (ai_status in ('waiting', 'done', 'error', 'skipped')),
  ai_tries integer not null default 0,
  ai_error text,
  ai_at timestamptz,
  note_added boolean not null default false,
  -- a worker has it until then (runs don't overlap on one recording)
  lease_until timestamptz,
  created_by uuid,
  created_at timestamptz not null default now(),
  constraint meeting_recordings_target check ((meeting_id is not null) <> (event_id is not null))
);
create unique index meeting_recordings_zoom on public.meeting_recordings (tenant_id, zoom_uuid) where zoom_uuid is not null;
create index meeting_recordings_meeting on public.meeting_recordings (meeting_id);
create index meeting_recordings_event on public.meeting_recordings (event_id);
create index meeting_recordings_work on public.meeting_recordings (copy_status, ai_status);

alter table public.meetings add column if not exists rec_checked_at timestamptz;
alter table public.events add column if not exists rec_checked_at timestamptz;

alter table public.meeting_recordings enable row level security;
-- read: whoever can see the meeting / the webinar date
create policy "meeting_recordings: read" on public.meeting_recordings for select to authenticated using (
  case when meeting_id is not null then private.has_permission(tenant_id, 'meetings', 'view') else private.can_see_event(event_id) end
);
-- add by hand: a member who can see it
create policy "meeting_recordings: add" on public.meeting_recordings for insert to authenticated with check (
  source = 'manual' and private.is_member(tenant_id)
  and case when meeting_id is not null then private.has_permission(tenant_id, 'meetings', 'view') else private.can_see_event(event_id) end
);
-- change / remove: only those added by hand
create policy "meeting_recordings: edit" on public.meeting_recordings for update to authenticated using (source = 'manual' and private.is_member(tenant_id)) with check (source = 'manual' and private.is_member(tenant_id));
create policy "meeting_recordings: remove" on public.meeting_recordings for delete to authenticated using (source = 'manual' and private.is_member(tenant_id));
grant select, insert, update, delete on public.meeting_recordings to authenticated;

-- the files: <tenant>/<yyyy>/<mm>/<file>
insert into storage.buckets (id, name, public) values ('meeting-recordings', 'meeting-recordings', false) on conflict (id) do nothing;
create policy "meeting-recordings: read" on storage.objects for select to authenticated
  using (bucket_id = 'meeting-recordings' and private.has_permission(((storage.foldername(name))[1])::uuid, 'meetings', 'view'));
create policy "meeting-recordings: upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'meeting-recordings' and private.is_member(((storage.foldername(name))[1])::uuid));

-- what the finder should look at: ended 30 min – 3 days ago, no recording yet, not checked in the last 30 minutes
create or replace function public.recording_due(p_limit integer default 10) returns table(kind text, id uuid)
language sql stable security definer set search_path = '' as $$
  (select 'meeting', m.id from public.meetings m
   where m.zoom_meeting_id is not null and m.zoom_account_id is not null and m.status <> 'cancelled'
     and ((m.meeting_date + m.end_time) at time zone 'Asia/Kolkata') between now() - interval '3 days' and now() - interval '30 minutes'
     and (m.rec_checked_at is null or m.rec_checked_at < now() - interval '30 minutes')
     and not exists (select 1 from public.meeting_recordings r where r.meeting_id = m.id and r.source = 'zoom')
   limit p_limit)
  union all
  (select 'event', e.id from public.events e
   where e.zoom_webinar_id is not null and e.zoom_account_id is not null and not e.is_cancelled
     and ((coalesce(e.end_date, e.event_date) + coalesce(e.end_time, e.start_time, time '23:00')) at time zone 'Asia/Kolkata') between now() - interval '3 days' and now() - interval '30 minutes'
     and (e.rec_checked_at is null or e.rec_checked_at < now() - interval '30 minutes')
     and not exists (select 1 from public.meeting_recordings r where r.event_id = e.id and r.source = 'zoom')
   limit p_limit)
$$;
revoke all on function public.recording_due(integer) from public, anon, authenticated;

-- the next recording to work on (copy or AI), held for 6 minutes
create or replace function public.recording_claim() returns uuid
language sql volatile security definer set search_path = '' as $$
  update public.meeting_recordings set lease_until = now() + interval '6 minutes'
  where id = (
    select id from public.meeting_recordings
    where ((copy_status = 'waiting' and copy_tries < 5) or (copy_status = 'done' and ai_status = 'waiting' and ai_tries < 3))
      and (lease_until is null or lease_until < now())
    order by created_at
    limit 1
    for update skip locked
  )
  returning id
$$;
revoke all on function public.recording_claim() from public, anon, authenticated;

create or replace function private.kick_zoom_long(p_body jsonb) returns void
language sql security definer set search_path = '' as $$
  select net.http_post(
    url := 'https://tnnjudehqalkgglzkfik.supabase.co/functions/v1/zoom',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-secret', public.workflow_cron_secret()),
    body := p_body,
    timeout_milliseconds := 300000
  );
$$;

select cron.schedule('zoom-recordings-find', '*/10 * * * *', $c$
  select private.kick_zoom('{"action":"rec_find"}'::jsonb) where exists (select 1 from public.recording_due(1));
$c$);
select cron.schedule('zoom-recordings-work', '* * * * *', $c$
  select private.kick_zoom_long('{"action":"rec_work"}'::jsonb)
  where exists (select 1 from public.meeting_recordings
                where ((copy_status = 'waiting' and copy_tries < 5) or (copy_status = 'done' and ai_status = 'waiting' and ai_tries < 3))
                  and (lease_until is null or lease_until < now()));
$c$);
