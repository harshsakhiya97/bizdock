-- Paid Podcast feedback (standard for every business):
-- 1. Lead category (leads.temperature): New, Hot, Warm, Cold, Not interested, Closed. New leads start New; Won → Closed,
--    Lost → Not interested, a done follow-up with a "not interested" outcome → Not interested.
-- 2. VSL form: an update-lead webhook submission marks the lead's extra.vsl_form_at (the "Form filled" step).
-- 3. Meetings: Upcoming (scheduled) / Done / No-show; meetings never change the lead (meeting_drop_lead goes).

-- 1. category
alter table public.leads drop constraint if exists leads_temperature_check;
alter table public.leads add constraint leads_temperature_check
  check (temperature = any (array['new', 'hot', 'warm', 'cold', 'not_interested', 'closed']));
alter table public.leads alter column temperature set default 'new';

create or replace function private.lead_category_from_stage() returns trigger
language plpgsql security definer set search_path = '' as $$
declare k text;
begin
  if new.temperature is null then new.temperature := 'new'; end if;
  if tg_op = 'INSERT' or new.stage_id is distinct from old.stage_id then
    select kind into k from public.funnel_stages where id = new.stage_id;
    if k = 'won' then new.temperature := 'closed';
    elsif k = 'lost' then new.temperature := 'not_interested';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists leads_category_from_stage on public.leads;
create trigger leads_category_from_stage before insert or update of stage_id, temperature on public.leads
  for each row execute function private.lead_category_from_stage();

create or replace function private.followup_not_interested() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.status = 'done' and new.outcome_id is not null
     and (tg_op = 'INSERT' or old.status is distinct from 'done' or old.outcome_id is distinct from new.outcome_id)
     and exists (select 1 from public.follow_up_outcomes o where o.id = new.outcome_id and o.name ~* 'not\s*interested') then
    update public.leads set temperature = 'not_interested' where id = new.lead_id and temperature is distinct from 'not_interested';
  end if;
  return new;
end $$;
drop trigger if exists follow_ups_not_interested on public.follow_ups;
create trigger follow_ups_not_interested after insert or update of status, outcome_id on public.follow_ups
  for each row execute function private.followup_not_interested();

-- existing leads: Won → Closed, Lost → Not interested, the rest New
update public.leads l set temperature = case s.kind when 'won' then 'closed' when 'lost' then 'not_interested' else 'new' end
  from public.funnel_stages s where s.id = l.stage_id and l.temperature is null;
update public.leads set temperature = 'new' where temperature is null;

-- 2. VSL form filled
create or replace function private.submission_vsl() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.lead_id is not null and new.action = 'update_lead' then
    update public.leads set extra = coalesce(extra, '{}'::jsonb) || jsonb_build_object('vsl_form_at', to_char(new.created_at at time zone 'Asia/Kolkata', 'YYYY-MM-DD"T"HH24:MI:SS'))
     where id = new.lead_id and not coalesce(extra, '{}'::jsonb) ? 'vsl_form_at';
  end if;
  return new;
end $$;
drop trigger if exists lead_submissions_vsl on public.lead_submissions;
create trigger lead_submissions_vsl after insert on public.lead_submissions
  for each row execute function private.submission_vsl();
update public.leads l set extra = coalesce(l.extra, '{}'::jsonb) || jsonb_build_object('vsl_form_at', to_char(s.at at time zone 'Asia/Kolkata', 'YYYY-MM-DD"T"HH24:MI:SS'))
  from (select lead_id, min(created_at) at from public.lead_submissions where action = 'update_lead' and lead_id is not null group by lead_id) s
 where l.id = s.lead_id and not coalesce(l.extra, '{}'::jsonb) ? 'vsl_form_at';

-- 3. meetings: Upcoming / Done / No-show; no change to the lead
drop trigger if exists meetings_drop_lead on public.meetings;
drop function if exists private.meeting_drop_lead();
alter table public.meetings drop constraint if exists meetings_status_check;
-- old statuses (Zoom isn't touched for these: its trigger is off while they change)
alter table public.meetings disable trigger meetings_zoom_upd;
update public.meetings set status = 'done', outcome_note = btrim(concat_ws(' · ', 'Qualified', nullif(outcome_note, ''))) where status = 'qualified';
update public.meetings set status = 'done', outcome_note = btrim(concat_ws(' · ', 'Not qualified', nullif(outcome_note, ''))) where status = 'not_qualified';
update public.meetings set status = 'no_show' where status = 'cancelled';
update public.meetings set status = 'done'
 where status = 'scheduled' and ((meeting_date + end_time) at time zone 'Asia/Kolkata') < now();
alter table public.meetings enable trigger meetings_zoom_upd;
alter table public.meetings add constraint meetings_status_check check (status = any (array['scheduled', 'done', 'no_show']));
