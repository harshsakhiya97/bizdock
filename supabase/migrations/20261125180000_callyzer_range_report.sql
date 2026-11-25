-- Callyzer → Report over a date range (like Team Report): the same numbers as callyzer_day_report for the days
-- p_from..p_to (India time); Calls (7 days) = the 7 days up to p_to.
create or replace function public.callyzer_range_report(p_tenant uuid, p_from date, p_to date)
returns jsonb
language sql stable security definer set search_path = '' as $$
  with b as (
    select (p_from::timestamp at time zone 'Asia/Kolkata') d0,
           ((p_to + 1)::timestamp at time zone 'Asia/Kolkata') d1,
           (least(p_from, p_to - 6)::timestamp at time zone 'Asia/Kolkata') a0,
           ((p_to - 6)::timestamp at time zone 'Asia/Kolkata') w0
    where private.has_permission(p_tenant, 'call_logs', 'view') or private.has_permission(p_tenant, 'settings', 'edit')
  ),
  tc as (
    select t.* from public.callyzer_team_calls t, b
     where t.tenant_id = p_tenant and t.emp_number is not null and t.started_at >= b.a0 and t.started_at < b.d1
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
           count(*) filter (where tc.started_at >= b.w0)::int calls_7d,
           (select count(*) from public.calls c
             where c.tenant_id = p_tenant and c.started_at >= b.d0 and c.started_at < b.d1 and c.transcript_status = 'done'
               and c.external_id in (select x.external_id from tc x where x.emp_number = tc.emp_number and x.started_at >= b.d0))::int ai_review
      from tc, b
     group by tc.emp_number, b.d0, b.d1, b.w0
  )
  select coalesce(jsonb_agg(to_jsonb(cz) order by cz.connected desc, cz.calls desc), '[]'::jsonb) from cz
$$;
revoke all on function public.callyzer_range_report(uuid, date, date) from public, anon;
grant execute on function public.callyzer_range_report(uuid, date, date) to authenticated;
