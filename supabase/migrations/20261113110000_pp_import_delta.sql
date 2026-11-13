-- The old Paid Podcast CRM kept running for a day after the import: what changed there since (a second backup, rows pushed
-- with purpose 'pp2'): new leads, comments (typed ones also as done follow-ups), WhatsApp messages, and leads it marked
-- Dead lead → Lost. Same mapping as pp_import_run (private.import_map, purpose 'pp'), so nothing is added twice.
create or replace function private.pp_import_delta(p_dry boolean default false) returns jsonb
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
  for r in select x.data from private.import_rows x where x.purpose = 'pp2' and x.kind = 'leads' and coalesce(x.data ->> 'deleted_at', '') = ''
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
    select x.data d from private.import_rows x where x.purpose = 'pp2' and x.kind = 'notes'
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
   where x.purpose = 'pp2' and x.kind = 'notes' on conflict do nothing;
  n := n || jsonb_build_object('notes', cnt);

  with ins as (
    insert into public.lead_activities (tenant_id, lead_id, kind, note, member_id, created_at)
    select c_tenant, m.lid, 'note', 'Final: ' || (x.data ->> 'final_comment'), (select mid from pp_users where old = x.data ->> 'final_by'),
           coalesce(private.pp_ts(x.data ->> 'final_at'), private.pp_ts(x.data ->> 'updated_at'), now())
      from private.import_rows x join pp_leadmap m on m.old = x.data ->> 'id'
     where x.purpose = 'pp2' and x.kind = 'leads' and coalesce(x.data ->> 'final_comment', '') <> ''
       and not exists (select 1 from private.import_map mp where mp.purpose = 'pp' and mp.kind = 'final' and mp.old_id = x.data ->> 'id')
    returning 1)
  select count(*) into cnt from ins;
  insert into private.import_map select 'pp', 'final', x.data ->> 'id', gen_random_uuid() from private.import_rows x
   where x.purpose = 'pp2' and x.kind = 'leads' and coalesce(x.data ->> 'final_comment', '') <> '' on conflict do nothing;
  n := n || jsonb_build_object('final_comments', cnt);

  -- ---------------- open follow-ups (overdue) ----------------
  with ins as (
    insert into public.follow_ups (tenant_id, lead_id, assigned_to, due_at, mode, purpose, status, created_at)
    select c_tenant, m.lid, m.owner,
           case when x.data ->> 'next_followup' ~ '^\d{4}-\d{2}-\d{2}$' then private.pp_ts(x.data ->> 'next_followup' || ' 11:00') else private.pp_ts(x.data ->> 'next_followup') end,
           'call', coalesce(nullif(x.data ->> 'fu_note', ''), 'Follow-up'), 'pending', coalesce(private.pp_ts(x.data ->> 'updated_at'), now())
      from private.import_rows x join pp_leadmap m on m.old = x.data ->> 'id'
     where x.purpose = 'pp2' and x.kind = 'leads' and coalesce(x.data ->> 'deleted_at', '') = '' and coalesce(x.data ->> 'next_followup', '') <> ''
       and not exists (select 1 from private.import_map mp where mp.purpose = 'pp' and mp.kind = 'followup' and mp.old_id = x.data ->> 'id')
    returning 1)
  select count(*) into cnt from ins;
  insert into private.import_map select 'pp', 'followup', x.data ->> 'id', gen_random_uuid() from private.import_rows x
   where x.purpose = 'pp2' and x.kind = 'leads' and coalesce(x.data ->> 'next_followup', '') <> '' on conflict do nothing;
  n := n || jsonb_build_object('follow_ups', cnt);

  -- ---------------- WhatsApp (WATI) messages → WhatsApp logs ----------------
  with ins as (
    insert into public.whatsapp_logs (tenant_id, direction, phone, lead_id, template, source, status, error, wati_id, sent_at)
    select c_tenant, case when x.data ->> 'direction' = 'in' then 'in' else 'out' end, regexp_replace(coalesce(x.data ->> 'phone', ''), '\D', '', 'g'), p.lid,
           nullif(x.data ->> 'template', ''), case when x.data ->> 'direction' = 'in' then 'reply' else 'app' end,
           case when x.data ->> 'direction' = 'in' then 'received'
                else case x.data ->> 'status' when 'delivered' then 'delivered' when 'read' then 'read' when 'replied' then 'read' when 'failed' then 'failed' else 'sent' end end,
           nullif(x.data ->> 'failed_reason', ''), nullif(x.data ->> 'msg_id', ''), coalesce(private.pp_ts(x.data ->> 'created_at'), now())
      from private.import_rows x left join pp_phone p on p.ph = right(regexp_replace(coalesce(x.data ->> 'phone', ''), '\D', '', 'g'), 10)
     where x.purpose = 'pp2' and x.kind = 'wati'
       and not exists (select 1 from public.whatsapp_logs w where w.tenant_id = c_tenant and w.wati_id = x.data ->> 'msg_id')
    returning 1)
  select count(*) into cnt from ins;
  n := n || jsonb_build_object('whatsapp', cnt);

  -- ---------------- the old CRM's typed follow-ups (not the automatic Callyzer ones) → done follow-ups ----------------
  with ins as (
    insert into public.follow_ups (tenant_id, lead_id, assigned_to, due_at, mode, purpose, status, outcome_id, result_note, completed_at, completed_by, created_by, created_at)
    select c_tenant, m.lid, u.mid, t.at, 'call', null, 'done',
           (select o.id from public.follow_up_outcomes o where o.tenant_id = c_tenant and o.name = case x.data ->> 'outcome'
              when 'Connected' then 'Connected – interested' when 'Not connected' then 'Not answered' when 'Busy' then 'Busy'
              when 'Switched off' then 'Switched off' when 'Wrong number' then 'Wrong number' end),
           nullif(btrim(x.data ->> 'note'), ''), t.at, u.mid, u.mid, t.at
      from private.import_rows x
      join pp_leadmap m on m.old = x.data ->> 'pplead_id'
      left join pp_users u on u.old = x.data ->> 'user_id'
      cross join lateral (select coalesce(private.pp_ts(x.data ->> 'created_at'), now()) as at) t
     where x.purpose = 'pp2' and x.kind = 'notes' and coalesce(x.data ->> 'auto', '0') <> '1'
       and not exists (select 1 from private.import_map mp where mp.purpose = 'pp' and mp.kind = 'note_fu' and mp.old_id = x.data ->> 'id')
    returning 1)
  select count(*) into cnt from ins;
  insert into private.import_map select 'pp', 'note_fu', x.data ->> 'id', gen_random_uuid() from private.import_rows x
   where x.purpose = 'pp2' and x.kind = 'notes' and coalesce(x.data ->> 'auto', '0') <> '1' on conflict do nothing;
  n := n || jsonb_build_object('follow_ups_done', cnt);

  -- ---------------- leads the old CRM moved to Dead lead / Not interested → Lost ----------------
  cnt := 0;
  for r in select x.data d, m.lid from private.import_rows x join pp_leadmap m on m.old = x.data ->> 'id'
            where x.purpose = 'pp2' and x.kind = 'status' and x.data ->> 'status' in ('Dead lead', 'Not interested') loop
    if exists (select 1 from public.leads l join public.funnel_stages s on s.id = l.stage_id where l.id = r.lid and s.kind in ('won', 'lost')) then continue; end if;
    t0 := coalesce(private.pp_ts(r.d ->> 'updated_at'), now());
    update public.leads set stage_id = s_lost, stage_changed_at = t0,
           lost_reason_id = (select id from public.lost_reasons where tenant_id = c_tenant and name = case when r.d ->> 'status' = 'Not interested' then 'Not interested' else 'Other' end)
     where id = r.lid;
    insert into public.lead_activities (tenant_id, lead_id, kind, note, created_at)
    values (c_tenant, r.lid, 'stage', 'Moved to Lost (old CRM: ' || (r.d ->> 'status') || ')', t0);
    cnt := cnt + 1;
  end loop;
  n := n || jsonb_build_object('moved_to_lost', cnt);
  return n;
end $$;
revoke all on function private.pp_import_delta(boolean) from public, anon, authenticated;
