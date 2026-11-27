-- Team Report: a done follow-up counts for the person who logged it (completed_by), not the one it was assigned to
-- (a manager logging a teammate's follow-up gets it). Pending ones (due / overdue) stay with who they're assigned to.
create or replace function public.team_report_range2(p_tenant uuid, p_from date, p_to date, p_business uuid default null, p_funnel uuid default null)
returns jsonb
language sql stable security definer set search_path = '' as $$
  with b as (
    select (p_from::timestamp at time zone 'Asia/Kolkata') d0,
           ((p_to + 1)::timestamp at time zone 'Asia/Kolkata') d1,
           ((p_to - 6)::timestamp at time zone 'Asia/Kolkata') w0,
           '00000000-0000-0000-0000-000000000000'::uuid zero
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
  fl as (
    select case when f.status = 'done' then f.completed_by else f.assigned_to end assigned_to, f.status, f.completed_at, f.due_at, coalesce(l.funnel_id, b.zero) fid
      from public.follow_ups f join public.leads l on l.id = f.lead_id, b
     where f.tenant_id = p_tenant
       and (p_business is null or l.business_id = p_business)
       and (p_funnel is null or coalesce(l.funnel_id, b.zero) = p_funnel)
  ),
  fu as (
    select fl.assigned_to mid, fl.fid,
           count(*) filter (where fl.status = 'done' and fl.completed_at >= b.d0 and fl.completed_at < b.d1)::int done,
           count(*) filter (where fl.status = 'done' and fl.completed_at >= b.w0 and fl.completed_at < b.d1)::int done_7d,
           count(*) filter (where fl.status = 'pending' and fl.due_at < now())::int overdue,
           count(*) filter (where fl.status = 'pending' and fl.due_at >= b.d0 and fl.due_at < b.d1)::int due,
           min(fl.completed_at) filter (where fl.status = 'done' and fl.completed_at >= b.d0 and fl.completed_at < b.d1) first_done,
           max(fl.completed_at) filter (where fl.status = 'done' and fl.completed_at >= b.d0 and fl.completed_at < b.d1) last_done
      from fl, b
     group by 1, 2
  ),
  open_leads as (
    select l.id, l.owner_id, coalesce(l.funnel_id, b.zero) fid
      from public.leads l
      left join public.funnel_stages s on s.id = l.stage_id, b
     where l.tenant_id = p_tenant and not coalesce(l.is_archived, false) and coalesce(s.kind, 'open') = 'open'
       and (p_business is null or l.business_id = p_business)
       and (p_funnel is null or coalesce(l.funnel_id, b.zero) = p_funnel)
  ),
  ld as (
    select o.owner_id mid, o.fid,
           count(*) filter (where not exists (select 1 from public.follow_ups f where f.lead_id = o.id and f.status = 'done')
                              and not exists (select 1 from public.calls c where c.lead_id = o.id))::int first_call_pending,
           count(*) filter (where not exists (select 1 from public.follow_ups f where f.lead_id = o.id and f.status = 'pending'))::int no_follow_up
      from open_leads o
     group by 1, 2
  ),
  pairs as (
    select coalesce(fu.mid, ld.mid) mid, coalesce(fu.fid, ld.fid) fid,
           coalesce(fu.done, 0) done, coalesce(fu.done_7d, 0) done_7d, coalesce(fu.overdue, 0) overdue, coalesce(fu.due, 0) due,
           fu.first_done, fu.last_done,
           coalesce(ld.first_call_pending, 0) first_call_pending, coalesce(ld.no_follow_up, 0) no_follow_up
      from fu full join ld on ld.mid = fu.mid and ld.fid = fu.fid
  ),
  per_mem as (
    select mid, sum(done)::int done, sum(done_7d)::int done_7d, sum(overdue)::int overdue, sum(due)::int due,
           min(first_done) first_done, max(last_done) last_done,
           sum(first_call_pending)::int first_call_pending, sum(no_follow_up)::int no_follow_up
      from pairs group by mid
  ),
  fun as (
    select x.fid, coalesce(f.name, 'No funnel') name,
           jsonb_agg(jsonb_build_object('id', mem.id, 'name', mem.name, 'role', mem.role,
             'done', x.done, 'done_7d', x.done_7d, 'overdue', x.overdue, 'due', x.due,
             'first_call_pending', x.first_call_pending, 'no_follow_up', x.no_follow_up)
             order by x.done desc, x.overdue desc, mem.name) rows,
           sum(x.done)::int done, sum(x.done_7d)::int done_7d, sum(x.overdue)::int overdue, sum(x.due)::int due,
           sum(x.first_call_pending)::int first_call_pending, sum(x.no_follow_up)::int no_follow_up
      from pairs x
      join mem on mem.id = x.mid
      left join public.funnels f on f.id = x.fid
     where x.done + x.done_7d + x.overdue + x.due + x.first_call_pending + x.no_follow_up > 0
     group by x.fid, f.name
  )
  select jsonb_build_object(
    'members', coalesce((select jsonb_agg(jsonb_build_object(
        'id', mem.id, 'name', mem.name, 'role', mem.role,
        'done', coalesce(pm.done, 0), 'done_7d', coalesce(pm.done_7d, 0), 'overdue', coalesce(pm.overdue, 0), 'due', coalesce(pm.due, 0),
        'first_done', pm.first_done, 'last_done', pm.last_done,
        'first_call_pending', coalesce(pm.first_call_pending, 0), 'no_follow_up', coalesce(pm.no_follow_up, 0))
        order by coalesce(pm.done, 0) desc, mem.name)
      from mem left join per_mem pm on pm.mid = mem.id), '[]'::jsonb),
    'funnels', coalesce((select jsonb_agg(jsonb_build_object('id', fun.fid, 'name', fun.name, 'rows', fun.rows,
        'done', fun.done, 'done_7d', fun.done_7d, 'overdue', fun.overdue, 'due', fun.due,
        'first_call_pending', fun.first_call_pending, 'no_follow_up', fun.no_follow_up)
        order by (fun.fid = '00000000-0000-0000-0000-000000000000'), fun.done desc, fun.overdue desc, fun.name)
      from fun), '[]'::jsonb)
  )
$$;
revoke all on function public.team_report_range2(uuid, date, date, uuid, uuid) from public, anon;
grant execute on function public.team_report_range2(uuid, date, date, uuid, uuid) to authenticated;

-- a number's records: as team_report_range_list, for the business / funnel; p_member null = everyone (a funnel's total)
create or replace function public.team_report_range_list2(p_tenant uuid, p_from date, p_to date, p_member uuid, p_kind text,
                                                          p_business uuid default null, p_funnel uuid default null)
returns jsonb
language sql stable security definer set search_path = '' as $$
  with b as (
    select (p_from::timestamp at time zone 'Asia/Kolkata') d0,
           ((p_to + 1)::timestamp at time zone 'Asia/Kolkata') d1,
           ((p_to - 6)::timestamp at time zone 'Asia/Kolkata') w0,
           '00000000-0000-0000-0000-000000000000'::uuid zero
    where private.has_permission(p_tenant, 'team_report', 'view')
  ),
  f as (
    select f.id, f.lead_id, f.due_at, f.completed_at, f.status, f.result_note, o.name outcome
      from public.follow_ups f
      join public.leads lx on lx.id = f.lead_id
      left join public.follow_up_outcomes o on o.id = f.outcome_id, b
     where f.tenant_id = p_tenant and (p_member is null or case when f.status = 'done' then f.completed_by else f.assigned_to end = p_member) and p_kind in ('done', 'done_7d', 'due', 'overdue')
       and (p_business is null or lx.business_id = p_business)
       and (p_funnel is null or coalesce(lx.funnel_id, b.zero) = p_funnel)
       and case p_kind
             when 'done' then f.status = 'done' and f.completed_at >= b.d0 and f.completed_at < b.d1
             when 'done_7d' then f.status = 'done' and f.completed_at >= b.w0 and f.completed_at < b.d1
             when 'due' then f.status = 'pending' and f.due_at >= b.d0 and f.due_at < b.d1
             when 'overdue' then f.status = 'pending' and f.due_at < now()
           end
  ),
  l as (
    select x.id lead_id, x.created_at, x.temperature, s.name stage
      from public.leads x
      left join public.funnel_stages s on s.id = x.stage_id, b
     where x.tenant_id = p_tenant and (p_member is null or x.owner_id = p_member) and p_kind in ('first_call_pending', 'no_follow_up')
       and not coalesce(x.is_archived, false) and coalesce(s.kind, 'open') = 'open'
       and (p_business is null or x.business_id = p_business)
       and (p_funnel is null or coalesce(x.funnel_id, b.zero) = p_funnel)
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
revoke all on function public.team_report_range_list2(uuid, date, date, uuid, text, uuid, uuid) from public, anon;
grant execute on function public.team_report_range_list2(uuid, date, date, uuid, text, uuid, uuid) to authenticated;
