-- Reports → Team Report: one day's work of the team (Indian time).
--   callyzer: one card per Callyzer number (all calls of the team phones, from callyzer_team_calls)
--   members:  one card per BizDock team member (follow-ups and their leads)
-- Permission team_report.view (Access control).
create or replace function public.team_report(p_tenant uuid, p_day date)
returns jsonb language sql stable security definer set search_path = '' as $$
  with b as (
    select (p_day::timestamp at time zone 'Asia/Kolkata') d0,
           ((p_day + 1)::timestamp at time zone 'Asia/Kolkata') d1,
           ((p_day - 6)::timestamp at time zone 'Asia/Kolkata') w0
    where private.has_permission(p_tenant, 'team_report', 'view')
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
    'callyzer', coalesce((select jsonb_agg(to_jsonb(cz) order by cz.connected desc, cz.calls desc) from cz where cz.calls > 0 or cz.calls_7d > 0), '[]'::jsonb),
    'members', coalesce((select jsonb_agg(jsonb_build_object(
        'id', mem.id, 'name', mem.name, 'role', mem.role,
        'done', coalesce(fu.done, 0), 'done_7d', coalesce(fu.done_7d, 0), 'overdue', coalesce(fu.overdue, 0), 'due', coalesce(fu.due, 0),
        'first_done', fu.first_done, 'last_done', fu.last_done,
        'first_call_pending', coalesce(ld.first_call_pending, 0), 'no_follow_up', coalesce(ld.no_follow_up, 0))
        order by coalesce(fu.done, 0) desc, mem.name)
      from mem left join fu on fu.assigned_to = mem.id left join ld on ld.owner_id = mem.id), '[]'::jsonb)
  )
$$;
revoke all on function public.team_report(uuid, date) from public, anon;
grant execute on function public.team_report(uuid, date) to authenticated;
