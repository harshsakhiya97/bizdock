-- Callyzer → Report (one card per Callyzer number) and Reports → Team Report (one card per team member), each with
-- the records behind every number (click a box).

-- Callyzer → Report: a day's calls per Callyzer number (Indian time)
create or replace function public.callyzer_day_report(p_tenant uuid, p_day date)
returns jsonb language sql stable security definer set search_path = '' as $$
  with b as (
    select (p_day::timestamp at time zone 'Asia/Kolkata') d0,
           ((p_day + 1)::timestamp at time zone 'Asia/Kolkata') d1,
           ((p_day - 6)::timestamp at time zone 'Asia/Kolkata') w0
    where private.has_permission(p_tenant, 'call_logs', 'view') or private.has_permission(p_tenant, 'settings', 'edit')
  ),
  tc as (
    select t.* from public.callyzer_team_calls t, b
     where t.tenant_id = p_tenant and t.emp_number is not null and t.started_at >= b.w0 and t.started_at < b.d1
  ),
  cz as (
    select tc.emp_number,
           (array_agg(tc.emp_name order by tc.started_at desc) filter (where tc.emp_name is not null))[1] emp_name,
           count(*) filter (where tc.started_at >= b.d0)::int calls,
           count(*) filter (where tc.started_at >= b.d0 and tc.duration_sec > 0)::int connected,
           count(*) filter (where tc.started_at >= b.d0 and coalesce(tc.duration_sec, 0) = 0)::int not_picked,
           count(*) filter (where tc.started_at >= b.d0 and tc.duration_sec >= 60)::int over_1min,
           coalesce(sum(tc.duration_sec) filter (where tc.started_at >= b.d0), 0)::int talk_sec,
           min(tc.started_at) filter (where tc.started_at >= b.d0) first_call,
           max(tc.started_at) filter (where tc.started_at >= b.d0) last_call,
           count(*)::int calls_7d,
           (select count(*) from public.calls c
             where c.tenant_id = p_tenant and c.started_at >= b.d0 and c.started_at < b.d1 and c.transcript_status = 'done'
               and c.external_id in (select x.external_id from tc x where x.emp_number = tc.emp_number and x.started_at >= b.d0))::int ai_review
      from tc, b
     group by tc.emp_number, b.d0, b.d1
  )
  select coalesce(jsonb_agg(to_jsonb(cz) order by cz.connected desc, cz.calls desc), '[]'::jsonb) from cz
$$;
revoke all on function public.callyzer_day_report(uuid, date) from public, anon;
grant execute on function public.callyzer_day_report(uuid, date) to authenticated;

-- one number's calls (now also: has an AI transcript)
drop function if exists public.callyzer_team_calls_of(uuid, text, timestamptz, timestamptz);
create function public.callyzer_team_calls_of(p_tenant uuid, p_emp text, p_from timestamptz, p_to timestamptz)
returns table(external_id text, started_at timestamptz, client_number text, call_type text, call_method text, call_mode text, duration_sec integer,
              recording_url text, recording_path text, lead_id uuid, lead_name text, transcribed boolean)
language sql stable security definer set search_path = '' as $$
  select c.external_id, c.started_at, c.client_number, c.call_type, c.call_method, c.call_mode, c.duration_sec, c.recording_url, c.recording_path,
         l.id, nullif(trim(concat_ws(' ', l.first_name, l.last_name)), ''),
         exists (select 1 from public.calls k where k.tenant_id = p_tenant and k.external_id = c.external_id and k.transcript_status = 'done')
    from public.callyzer_team_calls c
    left join lateral (
      select x.id, x.first_name, x.last_name from public.leads x
       where x.tenant_id = p_tenant and c.client_number is not null
         and right(regexp_replace(coalesce(x.phone, ''), '\D', '', 'g'), 10) = c.client_number
       order by x.created_at desc limit 1) l on true
   where c.tenant_id = p_tenant and c.emp_number = p_emp and c.started_at >= p_from and c.started_at < p_to
     and (private.has_permission(p_tenant, 'call_logs', 'view') or private.has_permission(p_tenant, 'settings', 'edit'))
   order by c.started_at desc
$$;
revoke all on function public.callyzer_team_calls_of(uuid, text, timestamptz, timestamptz) from public, anon;
grant execute on function public.callyzer_team_calls_of(uuid, text, timestamptz, timestamptz) to authenticated;

-- Reports → Team Report: team members only now
create or replace function public.team_report(p_tenant uuid, p_day date)
returns jsonb language sql stable security definer set search_path = '' as $$
  with b as (
    select (p_day::timestamp at time zone 'Asia/Kolkata') d0,
           ((p_day + 1)::timestamp at time zone 'Asia/Kolkata') d1,
           ((p_day - 6)::timestamp at time zone 'Asia/Kolkata') w0
    where private.has_permission(p_tenant, 'team_report', 'view')
  ),
  mem as (
    select m.id, coalesce(p.full_name, p.email) name, r.name role
      from public.tenant_members m
      join public.profiles p on p.id = m.user_id
      left join public.roles r on r.id = m.role_id
     where m.tenant_id = p_tenant and m.status = 'active' and not coalesce(m.is_support, false)
       and exists (select 1 from b)
  ),
  fu as (
    select f.assigned_to,
           count(*) filter (where f.status = 'done' and f.completed_at >= b.d0 and f.completed_at < b.d1)::int done,
           count(*) filter (where f.status = 'done' and f.completed_at >= b.w0 and f.completed_at < b.d1)::int done_7d,
           count(*) filter (where f.status = 'pending' and f.due_at < b.d0)::int overdue,
           count(*) filter (where f.status = 'pending' and f.due_at >= b.d0 and f.due_at < b.d1)::int due,
           min(f.completed_at) filter (where f.status = 'done' and f.completed_at >= b.d0 and f.completed_at < b.d1) first_done,
           max(f.completed_at) filter (where f.status = 'done' and f.completed_at >= b.d0 and f.completed_at < b.d1) last_done
      from public.follow_ups f, b
     where f.tenant_id = p_tenant
     group by f.assigned_to
  ),
  open_leads as (
    select l.id, l.owner_id from public.leads l
      left join public.funnel_stages s on s.id = l.stage_id
     where l.tenant_id = p_tenant and not coalesce(l.is_archived, false) and coalesce(s.kind, 'open') = 'open'
       and exists (select 1 from b)
  ),
  ld as (
    select o.owner_id,
           count(*) filter (where not exists (select 1 from public.follow_ups f where f.lead_id = o.id and f.status = 'done')
                              and not exists (select 1 from public.calls c where c.lead_id = o.id))::int first_call_pending,
           count(*) filter (where not exists (select 1 from public.follow_ups f where f.lead_id = o.id and f.status = 'pending'))::int no_follow_up
      from open_leads o
     group by o.owner_id
  )
  select jsonb_build_object(
    'members', coalesce((select jsonb_agg(jsonb_build_object(
        'id', mem.id, 'name', mem.name, 'role', mem.role,
        'done', coalesce(fu.done, 0), 'done_7d', coalesce(fu.done_7d, 0), 'overdue', coalesce(fu.overdue, 0), 'due', coalesce(fu.due, 0),
        'first_done', fu.first_done, 'last_done', fu.last_done,
        'first_call_pending', coalesce(ld.first_call_pending, 0), 'no_follow_up', coalesce(ld.no_follow_up, 0))
        order by coalesce(fu.done, 0) desc, mem.name)
      from mem left join fu on fu.assigned_to = mem.id left join ld on ld.owner_id = mem.id), '[]'::jsonb)
  )
$$;

-- the records behind one box of a member's card
--   done / done_7d / due / overdue: follow-ups · first_call_pending / no_follow_up: leads
create or replace function public.team_report_list(p_tenant uuid, p_day date, p_member uuid, p_kind text)
returns jsonb language sql stable security definer set search_path = '' as $$
  with b as (
    select (p_day::timestamp at time zone 'Asia/Kolkata') d0,
           ((p_day + 1)::timestamp at time zone 'Asia/Kolkata') d1,
           ((p_day - 6)::timestamp at time zone 'Asia/Kolkata') w0
    where private.has_permission(p_tenant, 'team_report', 'view')
  ),
  f as (
    select f.id, f.lead_id, f.due_at, f.completed_at, f.status, f.result_note, o.name outcome
      from public.follow_ups f
      left join public.follow_up_outcomes o on o.id = f.outcome_id, b
     where f.tenant_id = p_tenant and f.assigned_to = p_member and p_kind in ('done', 'done_7d', 'due', 'overdue')
       and case p_kind
             when 'done' then f.status = 'done' and f.completed_at >= b.d0 and f.completed_at < b.d1
             when 'done_7d' then f.status = 'done' and f.completed_at >= b.w0 and f.completed_at < b.d1
             when 'due' then f.status = 'pending' and f.due_at >= b.d0 and f.due_at < b.d1
             when 'overdue' then f.status = 'pending' and f.due_at < b.d0
           end
  ),
  l as (
    select x.id lead_id, x.created_at, x.temperature, s.name stage
      from public.leads x
      left join public.funnel_stages s on s.id = x.stage_id, b
     where x.tenant_id = p_tenant and x.owner_id = p_member and p_kind in ('first_call_pending', 'no_follow_up')
       and not coalesce(x.is_archived, false) and coalesce(s.kind, 'open') = 'open'
       and case p_kind
             when 'first_call_pending' then not exists (select 1 from public.follow_ups y where y.lead_id = x.id and y.status = 'done')
                                        and not exists (select 1 from public.calls c where c.lead_id = x.id)
             else not exists (select 1 from public.follow_ups y where y.lead_id = x.id and y.status = 'pending')
           end
  )
  select coalesce((
    select jsonb_agg(r order by r ->> 'at' desc nulls last) from (
      select jsonb_build_object('id', f.id, 'lead_id', f.lead_id, 'name', nullif(trim(concat_ws(' ', ld.first_name, ld.last_name)), ''),
               'phone', ld.phone, 'at', coalesce(f.completed_at, f.due_at), 'due_at', f.due_at, 'completed_at', f.completed_at,
               'outcome', f.outcome, 'note', f.result_note) r
        from f join public.leads ld on ld.id = f.lead_id
      union all
      select jsonb_build_object('id', l.lead_id, 'lead_id', l.lead_id, 'name', nullif(trim(concat_ws(' ', ld.first_name, ld.last_name)), ''),
               'phone', ld.phone, 'at', l.created_at, 'stage', l.stage, 'temperature', l.temperature)
        from l join public.leads ld on ld.id = l.lead_id
    ) q), '[]'::jsonb)
$$;
revoke all on function public.team_report_list(uuid, date, uuid, text) from public, anon;
grant execute on function public.team_report_list(uuid, date, uuid, text) to authenticated;
