-- One-time import of the old "AI Income CRM" Paid Podcast backup (rows pushed into private.import_rows, purpose 'pp')
-- into TVS → Paid Podcast → Paid Podcast Funnel. Safe to run again on a fresh backup: every old row is mapped once
-- (private.import_map), so a re-run only adds what's new. Original dates and times (India time) are kept.

create table if not exists private.import_map (purpose text not null, kind text not null, old_id text not null, new_id uuid not null, primary key (purpose, kind, old_id));

-- 'YYYY-MM-DD HH:MM[:SS]' (India time) → timestamptz; null when empty / unreadable
create or replace function private.pp_ts(v text) returns timestamptz language plpgsql immutable set search_path = '' as $$
begin
  if v is null or btrim(v) = '' then return null; end if;
  if v ~ '^\d{4}-\d{2}-\d{2}$' then return (v || ' 00:00')::timestamp at time zone 'Asia/Kolkata'; end if;
  return (substr(v, 1, 19))::timestamp at time zone 'Asia/Kolkata';
exception when others then return null;
end $$;

create or replace function private.pp_import_run(p_dry boolean default false) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  c_tenant constant uuid := 'cfdf9009-0f78-4041-83c1-1975ce98e234';
  c_biz constant uuid := 'bc0099a5-09a4-41eb-b2a2-e201b07ba590';
  c_sub constant uuid := '561b4e25-4923-4c5c-a7e2-b76a8c6679bd';
  c_funnel constant uuid := '500a4194-87f4-4b55-98c9-df9ce387335e';
  c_product constant uuid := '2375dbb6-5aec-4778-acc7-ec7da7cfc043';
  s_opted uuid := '46a8da5e-53a5-46e5-9f9b-07a2e892f91e';
  s_video uuid := '8d28e46a-7175-473e-9b52-f2d8d3e2d40d';
  s_booked uuid := 'cf63302a-f154-487a-b0c3-69d37f90c003';
  s_done uuid := '921968da-15cf-47fa-a666-5015efa6dc88';
  s_won uuid := '53b175cd-c58b-4313-b37d-dc5ced3a3c5f';
  s_lost uuid := '5135f9fb-de9e-417b-99bc-3dfbee3749ec';
  m_alka uuid;
  m_mana uuid := 'c934193d-6caf-4142-91a6-c5e61e733fbd';
  r record;
  d jsonb;
  lid uuid;
  nid uuid;
  ex record;
  stg uuid;
  st text;
  fn text;
  ln text;
  ph text;
  t0 timestamptz;
  t1 time;
  bt text;
  n jsonb := '{}'::jsonb;
  cnt int;
begin
  select m.id into m_alka from public.tenant_members m join public.profiles p on p.id = m.user_id
   where m.tenant_id = c_tenant and (lower(p.email) = 'alkakumawat12@gmail.com' or right(regexp_replace(coalesce(p.phone, ''), '\D', '', 'g'), 10) = '9372650235') limit 1;
  if m_alka is null and not p_dry then raise exception 'Add Alka Kumawat as a team member first.'; end if;

  -- member of an old user id (3 Alka, 4 Manashree; others aren't in BizDock)
  create temp table if not exists pp_users (old text primary key, mid uuid) on commit drop;
  delete from pp_users;
  insert into pp_users values ('3', m_alka), ('4', m_mana);

  -- ---------------- leads ----------------
  cnt := 0;
  for r in select x.data from private.import_rows x where x.purpose = 'pp' and x.kind = 'leads' and coalesce(x.data ->> 'deleted_at', '') = ''
           and not exists (select 1 from private.import_map mp where mp.purpose = 'pp' and mp.kind = 'lead' and mp.old_id = x.data ->> 'id')
           order by (x.data ->> 'id')::int loop
    d := r.data;
    ph := right(regexp_replace(coalesce(d ->> 'phone', ''), '\D', '', 'g'), 10);
    st := d ->> 'status';
    stg := case
      when st = 'Booked' or exists (select 1 from private.import_rows b where b.purpose = 'pp' and b.kind = 'bookings' and b.data ->> 'pplead_id' = d ->> 'id') then s_won
      when st in ('Not interested', 'Dead lead') then s_lost
      when d ->> 'meet_status' = 'Done' then s_done
      when coalesce(d ->> 'cb_status', '') in ('filled', 'scheduled') then s_booked
      when coalesce(nullif(d ->> 'vsl_secs', ''), '0')::numeric > 0 then s_video
      else s_opted end;
    fn := split_part(btrim(coalesce(d ->> 'name', '')), ' ', 1);
    ln := nullif(btrim(substr(btrim(coalesce(d ->> 'name', '')), length(fn) + 1)), '');
    t0 := coalesce(private.pp_ts(d ->> 'form_time'), private.pp_ts(d ->> 'created_at'), now());
    -- the extra fields that have a value
    d := d || jsonb_build_object('_extra', jsonb_strip_nulls(jsonb_build_object(
      'submitted_at', nullif(d ->> 'form_time', ''),
      'what_describes_you_best', nullif(d ->> 'describe', ''),
      'budget', nullif(d ->> 'budget', ''), 'timeline', nullif(d ->> 'timeline', ''),
      'business', nullif(d ->> 'business', ''), 'revenue', nullif(d ->> 'revenue', ''),
      'tried_before', nullif(d ->> 'tried_before', ''), 'ready_to_invest', nullif(d ->> 'invest_ready', ''),
      'travel_ok', nullif(d ->> 'travel_ok', ''), 'goal', nullif(d ->> 'goal', ''),
      'vsl_watched_seconds', nullif(nullif(d ->> 'vsl_secs', ''), '0'),
      'call_booked_at', nullif(d ->> 'cb_time', ''), 'meeting_time', nullif(d ->> 'meeting_time', ''),
      'meeting_link', nullif(d ->> 'meeting_link', ''), 'sheet_meeting_time', nullif(d ->> 'sheet_meeting_time', ''),
      'meeting_status', nullif(d ->> 'meet_status', ''), 'meeting_note', nullif(d ->> 'meet_note', ''),
      'research', nullif(d ->> 'research', ''),
      'instagram', nullif(d ->> 'link_instagram', ''), 'youtube', nullif(d ->> 'link_youtube', ''),
      'linkedin', nullif(d ->> 'link_linkedin', ''), 'facebook', nullif(d ->> 'link_facebook', ''),
      'website', nullif(d ->> 'link_website', ''), 'business_category', nullif(d ->> 'biz_category', ''),
      'podcast_before', nullif(d ->> 'podcast_before', ''), 'pain_area', nullif(d ->> 'pain_area', ''),
      'years_in_business', nullif(d ->> 'years_in_biz', ''), 'team_size', nullif(d ->> 'team_size', ''),
      'ticket_size', nullif(d ->> 'ticket_size', ''), 'marketing_spend', nullif(d ->> 'mkt_spend', ''),
      'role_model', nullif(d ->> 'role_model', ''), 'competitor', nullif(d ->> 'competitor', ''),
      'client_source', nullif(d ->> 'client_source', ''), 'decision_maker', nullif(d ->> 'decision_maker', ''),
      'follow_up_note', nullif(d ->> 'fu_note', ''),
      'old_crm_status', nullif(d ->> 'status', ''), 'old_crm_id', d ->> 'id'
    )));
    select l.* into ex from public.leads l
     where l.tenant_id = c_tenant and l.funnel_id = c_funnel and right(regexp_replace(coalesce(l.phone, ''), '\D', '', 'g'), 10) = ph limit 1;
    if ex.id is not null then
      lid := ex.id;
      if not p_dry then
        update public.leads set
          first_name = coalesce(nullif(first_name, ''), fn), last_name = coalesce(last_name, ln),
          email = coalesce(email, nullif(d ->> 'email', '')), city = coalesce(city, nullif(d ->> 'city', '')),
          owner_id = coalesce((select mid from pp_users where old = d ->> 'owner_id'), owner_id),
          stage_id = stg, extra = coalesce(extra, '{}'::jsonb) || (d -> '_extra'),
          notes = coalesce(notes, nullif(d ->> 'last_comment', '')), purpose = coalesce(purpose, nullif(d ->> 'purpose', '')),
          utm_campaign = coalesce(utm_campaign, nullif(d ->> 'campaign', '')), utm_term = coalesce(utm_term, nullif(d ->> 'adset', '')),
          utm_content = coalesce(utm_content, nullif(d ->> 'ad', '')),
          created_at = least(created_at, t0)
         where id = lid;
      end if;
    elsif not p_dry then
      insert into public.leads (tenant_id, business_id, sub_business_id, funnel_id, stage_id, first_name, last_name, phone, email, city,
                                source_id, owner_id, notes, purpose, utm_source, utm_campaign, utm_term, utm_content, extra, lost_reason_id,
                                created_at, updated_at, stage_changed_at)
      values (c_tenant, c_biz, c_sub, c_funnel, stg, coalesce(nullif(fn, ''), 'Lead'), ln, ph, nullif(d ->> 'email', ''), nullif(d ->> 'city', ''),
              (select s.id from public.lead_sources s where s.tenant_id = c_tenant and s.name = case d ->> 'source'
                  when 'fb' then 'Facebook' when 'ig' then 'Instagram' when 'wa' then 'WhatsApp' when 'manual' then 'Direct' else 'Other' end),
              (select mid from pp_users where old = d ->> 'owner_id'),
              nullif(d ->> 'last_comment', ''), nullif(d ->> 'purpose', ''), nullif(d ->> 'source', ''),
              nullif(d ->> 'campaign', ''), nullif(d ->> 'adset', ''), nullif(d ->> 'ad', ''), d -> '_extra',
              case when stg = s_lost then (select id from public.lost_reasons where tenant_id = c_tenant and name = case when st = 'Not interested' then 'Not interested' else 'Other' end) end,
              t0, coalesce(private.pp_ts(d ->> 'updated_at'), t0), coalesce(private.pp_ts(d ->> 'updated_at'), t0))
      returning id into lid;
      insert into public.lead_activities (tenant_id, lead_id, kind, note, created_at)
      values (c_tenant, lid, 'created', 'Lead received' || coalesce(' from ' || case d ->> 'source' when 'fb' then 'Facebook' when 'ig' then 'Instagram'
              when 'wa' then 'WhatsApp' when 'manual' then 'manual entry' else null end, '') || coalesce(' · ' || nullif(d ->> 'campaign', ''), '') || ' (imported from AI Income CRM)', t0);
    end if;
    if not p_dry then
      insert into public.lead_submissions (tenant_id, lead_id, funnel_id, via, is_new, utm_source, utm_campaign, utm_term, utm_content, data, created_at, result)
      values (c_tenant, lid, c_funnel, 'import', ex.id is null, nullif(d ->> 'source', ''), nullif(d ->> 'campaign', ''), nullif(d ->> 'adset', ''), nullif(d ->> 'ad', ''),
              (d - '_extra') - 'deleted_at', t0, case when ex.id is null then 'created' else 'updated' end);
      insert into private.import_map values ('pp', 'lead', d ->> 'id', lid);
    end if;
    cnt := cnt + 1;
  end loop;
  n := n || jsonb_build_object('leads', cnt);
  if p_dry then return n; end if;

  create temp table if not exists pp_leadmap (old text primary key, lid uuid, owner uuid) on commit drop;
  delete from pp_leadmap;
  insert into pp_leadmap select mp.old_id, mp.new_id, l.owner_id from private.import_map mp join public.leads l on l.id = mp.new_id where mp.purpose = 'pp' and mp.kind = 'lead';
  create temp table if not exists pp_phone (ph text primary key, lid uuid) on commit drop;
  delete from pp_phone;
  insert into pp_phone select distinct on (right(regexp_replace(l.phone, '\D', '', 'g'), 10)) right(regexp_replace(l.phone, '\D', '', 'g'), 10), l.id
    from pp_leadmap m join public.leads l on l.id = m.lid order by right(regexp_replace(l.phone, '\D', '', 'g'), 10), l.created_at;

  -- ---------------- notes (and the "Final" comment, and the journey's status / booking / payment lines) ----------------
  with src as (
    select x.data d from private.import_rows x where x.purpose = 'pp' and x.kind = 'notes'
       and not exists (select 1 from private.import_map mp where mp.purpose = 'pp' and mp.kind = 'note' and mp.old_id = x.data ->> 'id')
  ), ins as (
    insert into public.lead_activities (tenant_id, lead_id, kind, note, member_id, created_at)
    select c_tenant, m.lid, 'note',
           btrim(coalesce(nullif(btrim(s.d ->> 'note'), ''), '') || case when coalesce(s.d ->> 'outcome', '') <> '' then ' · ' || (s.d ->> 'outcome') else '' end, ' ·'),
           (select mid from pp_users where old = s.d ->> 'user_id'),
           coalesce(private.pp_ts(s.d ->> 'created_at'), now())
      from src s join pp_leadmap m on m.old = s.d ->> 'pplead_id'
     where coalesce(nullif(btrim(s.d ->> 'note'), ''), nullif(s.d ->> 'outcome', '')) is not null
    returning 1)
  select count(*) into cnt from ins;
  insert into private.import_map select 'pp', 'note', x.data ->> 'id', gen_random_uuid() from private.import_rows x
   where x.purpose = 'pp' and x.kind = 'notes' on conflict do nothing;
  n := n || jsonb_build_object('notes', cnt);

  with ins as (
    insert into public.lead_activities (tenant_id, lead_id, kind, note, member_id, created_at)
    select c_tenant, m.lid, 'note', 'Final: ' || (x.data ->> 'final_comment'), (select mid from pp_users where old = x.data ->> 'final_by'),
           coalesce(private.pp_ts(x.data ->> 'final_at'), private.pp_ts(x.data ->> 'updated_at'), now())
      from private.import_rows x join pp_leadmap m on m.old = x.data ->> 'id'
     where x.purpose = 'pp' and x.kind = 'leads' and coalesce(x.data ->> 'final_comment', '') <> ''
       and not exists (select 1 from private.import_map mp where mp.purpose = 'pp' and mp.kind = 'final' and mp.old_id = x.data ->> 'id')
    returning 1)
  select count(*) into cnt from ins;
  insert into private.import_map select 'pp', 'final', x.data ->> 'id', gen_random_uuid() from private.import_rows x
   where x.purpose = 'pp' and x.kind = 'leads' and coalesce(x.data ->> 'final_comment', '') <> '' on conflict do nothing;
  n := n || jsonb_build_object('final_comments', cnt);

  with ins as (
    insert into public.lead_activities (tenant_id, lead_id, kind, note, member_id, created_at)
    select c_tenant, m.lid, 'note', btrim(coalesce(x.data ->> 'title', '') || coalesce(' — ' || nullif(x.data ->> 'detail', ''), '')),
           (select mid from pp_users where old = x.data ->> 'user_id'), coalesce(private.pp_ts(x.data ->> 'created_at'), now())
      from private.import_rows x join pp_leadmap m on m.old = x.data ->> 'pplead_id'
     where x.purpose = 'pp' and x.kind = 'journey'
       and not exists (select 1 from private.import_map mp where mp.purpose = 'pp' and mp.kind = 'journey' and mp.old_id = x.data ->> 'id')
    returning 1)
  select count(*) into cnt from ins;
  insert into private.import_map select 'pp', 'journey', x.data ->> 'id', gen_random_uuid() from private.import_rows x
   where x.purpose = 'pp' and x.kind = 'journey' on conflict do nothing;
  n := n || jsonb_build_object('journey', cnt);

  -- ---------------- meetings (no future ones; the year-2027 sheet dates are 2026) ----------------
  cnt := 0;
  for r in select x.data d from private.import_rows x where x.purpose = 'pp' and x.kind = 'meetings'
           and not exists (select 1 from private.import_map mp where mp.purpose = 'pp' and mp.kind = 'meeting' and mp.old_id = x.data ->> 'id')
           order by x.data ->> 'meet_at' loop
    d := r.d;
    select * into ex from pp_leadmap where old = d ->> 'pplead_id';
    if ex.lid is null then continue; end if;
    t0 := private.pp_ts(regexp_replace(coalesce(d ->> 'meet_at', ''), '^2027-', '2026-'));
    if t0 is null or t0 >= now() then continue; end if;
    t1 := (t0 at time zone 'Asia/Kolkata')::time;
    insert into public.meetings (tenant_id, business_id, sub_business_id, lead_id, meeting_date, start_time, end_time, mode, link, status, outcome_note,
                                 created_by, assigned_to, created_at, updated_at)
    values (c_tenant, c_biz, c_sub, ex.lid, (t0 at time zone 'Asia/Kolkata')::date, t1, case when t1 >= time '23:29' then time '23:59' else t1 + interval '30 minutes' end,
            'online', nullif(d ->> 'meet_link', ''),
            case d ->> 'status' when 'Done' then case when d ->> 'outcome' = 'Not interested' then 'not_qualified' else 'qualified' end
                                when 'No-show' then 'no_show' when 'Rescheduled' then 'cancelled' when 'Cancelled' then 'cancelled' else 'scheduled' end,
            nullif(btrim(concat_ws(' · ', nullif(d ->> 'outcome', ''), case when d ->> 'status' = 'Rescheduled' then 'Rescheduled' end,
                                   nullif(d ->> 'reason', ''), nullif(d ->> 'note', ''))), ''),
            (select mid from pp_users where old = d ->> 'created_by'), ex.owner,
            coalesce(private.pp_ts(d ->> 'created_at'), t0), coalesce(private.pp_ts(d ->> 'updated_at'), private.pp_ts(d ->> 'created_at'), t0))
    returning id into nid;
    insert into private.import_map values ('pp', 'meeting', d ->> 'id', nid);
    cnt := cnt + 1;
  end loop;
  n := n || jsonb_build_object('meetings', cnt);

  -- ---------------- bookings and their payments ----------------
  cnt := 0;
  for r in select x.data d from private.import_rows x where x.purpose = 'pp' and x.kind = 'bookings'
           and not exists (select 1 from private.import_map mp where mp.purpose = 'pp' and mp.kind = 'booking' and mp.old_id = x.data ->> 'id') loop
    d := r.d;
    select * into ex from pp_leadmap where old = d ->> 'pplead_id';
    -- the old CRM lost am / pm: 05:00 → 5 pm, 02:00 → 2 pm
    bt := case d ->> 'btime' when '05:00' then '17:00' when '02:00' then '14:00' else coalesce(nullif(d ->> 'btime', ''), '11:00') end;
    begin
    insert into public.bookings (tenant_id, business_id, sub_business_id, lead_id, client_name, phone, purpose, booking_date, start_time, end_time,
                                 amount, gst_applicable, gst_rate, status, invoice_no, invoice_date, notes, owner_id, created_by, product_id, created_at, updated_at)
    values (c_tenant, c_biz, c_sub, ex.lid, coalesce(nullif(d ->> 'client', ''), 'Client'), right(regexp_replace(coalesce(d ->> 'phone', ''), '\D', '', 'g'), 10),
            nullif(d ->> 'purpose', ''), (d ->> 'bdate')::date, bt::time,
            case when bt::time >= time '21:59' then time '23:59' else bt::time + make_interval(mins => (coalesce((d ->> 'duration_hrs')::numeric, 2) * 60)::int) end,
            coalesce((d ->> 'amount')::numeric, 0), false, 0,
            case d ->> 'status' when 'Completed' then 'completed' when 'Cancelled' then 'cancelled' else 'confirmed' end,
            nullif(d ->> 'inv_no', ''), (nullif(d ->> 'inv_date', ''))::date, nullif(d ->> 'notes', ''), ex.owner,
            (select mid from pp_users where old = d ->> 'created_by'), c_product,
            coalesce(private.pp_ts(d ->> 'created_at'), now()), coalesce(private.pp_ts(d ->> 'updated_at'), private.pp_ts(d ->> 'created_at'), now()))
    returning id into nid;
    exception when others then
      -- e.g. the studio is booked at that time: reported, the rest goes on
      n := n || jsonb_build_object('booking_skipped_' || (d ->> 'id'), (d ->> 'client') || ': ' || sqlerrm);
      continue;
    end;
    -- the "Booked" stage line the booking adds: at the booking's own time
    update public.lead_activities set created_at = coalesce(private.pp_ts(d ->> 'created_at'), created_at)
     where lead_id = ex.lid and kind = 'stage' and note like 'Booked %' and created_at > now() - interval '5 minutes';
    insert into private.import_map values ('pp', 'booking', d ->> 'id', nid);
    cnt := cnt + 1;
  end loop;
  n := n || jsonb_build_object('bookings', cnt);

  with ins as (
    insert into public.booking_payments (tenant_id, booking_id, amount, paid_on, payment_mode_id, note, received_by, label, status, created_at)
    select c_tenant, mp.new_id, (x.data ->> 'amount')::numeric, (x.data ->> 'pay_date')::date,
           (select pm.id from public.payment_modes pm where pm.tenant_id = c_tenant and pm.name = x.data ->> 'mode'),
           nullif(x.data ->> 'note', ''), (select mid from pp_users where old = x.data ->> 'created_by'), nullif(x.data ->> 'kind', ''), 'paid',
           coalesce(private.pp_ts(x.data ->> 'created_at'), now())
      from private.import_rows x join private.import_map mp on mp.purpose = 'pp' and mp.kind = 'booking' and mp.old_id = x.data ->> 'booking_id'
     where x.purpose = 'pp' and x.kind = 'payments' and (x.data ->> 'amount')::numeric > 0
       and not exists (select 1 from private.import_map m2 where m2.purpose = 'pp' and m2.kind = 'payment' and m2.old_id = x.data ->> 'id')
    returning 1)
  select count(*) into cnt from ins;
  insert into private.import_map select 'pp', 'payment', x.data ->> 'id', gen_random_uuid() from private.import_rows x
   where x.purpose = 'pp' and x.kind = 'payments' on conflict do nothing;
  n := n || jsonb_build_object('payments', cnt);

  -- ---------------- open follow-ups (overdue) ----------------
  with ins as (
    insert into public.follow_ups (tenant_id, lead_id, assigned_to, due_at, mode, purpose, status, created_at)
    select c_tenant, m.lid, m.owner,
           case when x.data ->> 'next_followup' ~ '^\d{4}-\d{2}-\d{2}$' then private.pp_ts(x.data ->> 'next_followup' || ' 11:00') else private.pp_ts(x.data ->> 'next_followup') end,
           'call', coalesce(nullif(x.data ->> 'fu_note', ''), 'Follow-up'), 'pending', coalesce(private.pp_ts(x.data ->> 'updated_at'), now())
      from private.import_rows x join pp_leadmap m on m.old = x.data ->> 'id'
     where x.purpose = 'pp' and x.kind = 'leads' and coalesce(x.data ->> 'deleted_at', '') = '' and coalesce(x.data ->> 'next_followup', '') <> ''
       and not exists (select 1 from private.import_map mp where mp.purpose = 'pp' and mp.kind = 'followup' and mp.old_id = x.data ->> 'id')
    returning 1)
  select count(*) into cnt from ins;
  insert into private.import_map select 'pp', 'followup', x.data ->> 'id', gen_random_uuid() from private.import_rows x
   where x.purpose = 'pp' and x.kind = 'leads' and coalesce(x.data ->> 'next_followup', '') <> '' on conflict do nothing;
  n := n || jsonb_build_object('follow_ups', cnt);

  -- ---------------- calls ----------------
  with ins as (
    insert into public.calls (tenant_id, business_id, sub_business_id, lead_id, member_id, phone, agent_phone, direction, started_at, duration_sec,
                              outcome, purpose, recording_url, recording_file, transcript, ai, ai_status, interest_score, budget_signal, timeline_signal,
                              followup_days, source, external_id, created_at)
    select c_tenant, c_biz, c_sub, p.lid, (select mid from pp_users where old = x.data ->> 'user_id'),
           right(regexp_replace(coalesce(x.data ->> 'phone', ''), '\D', '', 'g'), 10), nullif(x.data ->> 'agent_no', ''),
           case lower(coalesce(x.data ->> 'call_type', '')) when 'incoming' then 'incoming' when 'outgoing' then 'outgoing' when 'missed' then 'missed'
                when 'rejected' then 'rejected' else 'unknown' end,
           coalesce(private.pp_ts((x.data ->> 'call_date') || ' ' || coalesce(nullif(x.data ->> 'call_time', ''), '00:00')), private.pp_ts(x.data ->> 'created_at'), now()),
           nullif(x.data ->> 'duration_sec', '')::int, nullif(x.data ->> 'outcome', ''), nullif(x.data ->> 'call_purpose', ''),
           coalesce(nullif(x.data ->> 'rec_url', ''), nullif(x.data ->> 'drive_url', '')), nullif(x.data ->> 'rec_file', ''),
           nullif(x.data ->> 'transcript', ''), case when jsonb_typeof(x.data -> 'ai_json') = 'object' then x.data -> 'ai_json' end,
           nullif(x.data ->> 'ai_status', ''), nullif(x.data ->> 'interest_score', '')::int, nullif(x.data ->> 'budget_signal', ''),
           nullif(x.data ->> 'timeline_signal', ''), nullif(x.data ->> 'followup_days', '')::int, 'import', 'pp:' || (x.data ->> 'id'),
           coalesce(private.pp_ts(x.data ->> 'created_at'), now())
      from private.import_rows x left join pp_phone p on p.ph = right(regexp_replace(coalesce(x.data ->> 'phone', ''), '\D', '', 'g'), 10)
     where x.purpose = 'pp' and x.kind = 'calls'
    on conflict (tenant_id, source, external_id) where external_id is not null do nothing
    returning 1)
  select count(*) into cnt from ins;
  n := n || jsonb_build_object('calls', cnt);

  -- ---------------- WhatsApp (WATI) messages → WhatsApp logs ----------------
  with ins as (
    insert into public.whatsapp_logs (tenant_id, direction, phone, lead_id, template, source, status, error, wati_id, sent_at)
    select c_tenant, case when x.data ->> 'direction' = 'in' then 'in' else 'out' end, regexp_replace(coalesce(x.data ->> 'phone', ''), '\D', '', 'g'), p.lid,
           nullif(x.data ->> 'template', ''), case when x.data ->> 'direction' = 'in' then 'reply' else 'app' end,
           case when x.data ->> 'direction' = 'in' then 'received'
                else case x.data ->> 'status' when 'delivered' then 'delivered' when 'read' then 'read' when 'replied' then 'read' when 'failed' then 'failed' else 'sent' end end,
           nullif(x.data ->> 'failed_reason', ''), nullif(x.data ->> 'msg_id', ''), coalesce(private.pp_ts(x.data ->> 'created_at'), now())
      from private.import_rows x left join pp_phone p on p.ph = right(regexp_replace(coalesce(x.data ->> 'phone', ''), '\D', '', 'g'), 10)
     where x.purpose = 'pp' and x.kind = 'wati'
       and not exists (select 1 from public.whatsapp_logs w where w.tenant_id = c_tenant and w.wati_id = x.data ->> 'msg_id')
    returning 1)
  select count(*) into cnt from ins;
  n := n || jsonb_build_object('whatsapp', cnt);

  -- ---------------- ad spend ----------------
  with ins as (
    insert into public.ad_spend (tenant_id, business_id, sub_business_id, funnel_id, spend_date, amount, leads, bookings, impressions, clicks,
                                 landing_page_views, add_to_cart, purchases, notes, source, updated_at)
    select c_tenant, c_biz, c_sub, c_funnel, (x.data ->> 'spend_date')::date, coalesce((x.data ->> 'amount')::numeric, 0),
           nullif(x.data ->> 'leads', '')::int, nullif(x.data ->> 'bookings', '')::int, nullif(x.data ->> 'impressions', '')::int,
           nullif(x.data ->> 'clicks', '')::int, nullif(x.data ->> 'lpv', '')::int, nullif(x.data ->> 'atc', '')::int,
           nullif(x.data ->> 'purchases', '')::int, nullif(x.data ->> 'annotations', ''), 'import', now()
      from private.import_rows x where x.purpose = 'pp' and x.kind = 'ad_spend'
    on conflict (funnel_id, spend_date) do update set amount = excluded.amount, leads = excluded.leads, bookings = excluded.bookings,
      impressions = excluded.impressions, clicks = excluded.clicks, landing_page_views = excluded.landing_page_views,
      add_to_cart = excluded.add_to_cart, purchases = excluded.purchases, notes = excluded.notes, updated_at = now()
    returning 1)
  select count(*) into cnt from ins;
  n := n || jsonb_build_object('ad_spend_days', cnt);
  return n;
end $$;
revoke all on function private.pp_import_run(boolean) from public, anon, authenticated;
