-- Dashboard (owner): the follow-ups, meetings, calls, leads to call and overdue payments behind a Team / Calls / Needs attention number
create or replace function public.owner_dash_records(p_tenant uuid, p_from date, p_to date, p_kind text, p_member uuid default null,
                                                     p_emp text default null, p_business uuid default null)
returns jsonb
language sql stable security definer set search_path = '' as $$
  with b as (
    select (p_from::timestamp at time zone 'Asia/Kolkata') d0, ((p_to + 1)::timestamp at time zone 'Asia/Kolkata') d1,
           (now() at time zone 'Asia/Kolkata')::date today
     where private.is_owner_view(p_tenant)
  ),
  lead_of as (
    select l.id, nullif(trim(concat_ws(' ', l.first_name, l.last_name)), '') name, l.phone, l.business_id,
           right(regexp_replace(coalesce(l.phone, ''), '\D', '', 'g'), 10) p10
      from public.leads l where l.tenant_id = p_tenant
  ),
  who as (
    select m.id, coalesce(p.full_name, p.email) name from public.tenant_members m join public.profiles p on p.id = m.user_id where m.tenant_id = p_tenant
  ),
  r as (
    -- follow-ups logged by the member in the dates
    select f.id, f.lead_id, lo.name, lo.phone, f.completed_at at_, o.name what, f.result_note note, null::text extra
      from public.follow_ups f join lead_of lo on lo.id = f.lead_id left join public.follow_up_outcomes o on o.id = f.outcome_id, b
     where p_kind = 'fu_done' and f.tenant_id = p_tenant and f.status = 'done' and f.completed_by = p_member
       and f.completed_at >= b.d0 and f.completed_at < b.d1 and (p_business is null or lo.business_id = p_business)
    union all
    -- overdue / due today (a member's, or everyone's)
    select f.id, f.lead_id, lo.name, lo.phone, f.due_at, case when f.due_at < now() then 'Overdue' else 'Due today' end, null, w.name
      from public.follow_ups f join lead_of lo on lo.id = f.lead_id left join who w on w.id = f.assigned_to, b
     where p_kind in ('overdue', 'due_today') and f.tenant_id = p_tenant and f.status = 'pending'
       and (p_member is null or f.assigned_to = p_member) and (p_business is null or lo.business_id = p_business)
       and case p_kind when 'overdue' then f.due_at < now() else (f.due_at at time zone 'Asia/Kolkata')::date = b.today end
    union all
    -- meetings held by the member in the dates
    select m.id, m.lead_id, coalesce(lo.name, m.title, 'Meeting'), lo.phone, (m.meeting_date + m.start_time) at time zone 'Asia/Kolkata', 'Meeting done', m.outcome_note, null
      from public.meetings m left join lead_of lo on lo.id = m.lead_id, b
     where p_kind = 'meetings' and m.tenant_id = p_tenant and m.assigned_to = p_member and m.status = 'done'
       and m.meeting_date between p_from and p_to and (p_business is null or m.business_id = p_business)
    union all
    -- the member's new / closed leads in the dates
    select l.id, l.id, lo.name, lo.phone, l.created_at, coalesce(s.name, 'Lead'), null, l.temperature
      from public.leads l join lead_of lo on lo.id = l.id left join public.funnel_stages s on s.id = l.stage_id, b
     where p_kind in ('leads', 'closed') and l.tenant_id = p_tenant and l.owner_id = p_member and not coalesce(l.is_archived, false)
       and l.created_at >= b.d0 and l.created_at < b.d1 and (p_business is null or l.business_id = p_business)
       and (p_kind = 'leads' or l.temperature = 'closed' or s.kind = 'won')
    union all
    -- leads with no call yet / no next follow-up
    select l.id, l.id, lo.name, lo.phone, l.created_at, coalesce(s.name, 'Lead'), null, w.name
      from public.leads l join lead_of lo on lo.id = l.id left join public.funnel_stages s on s.id = l.stage_id left join who w on w.id = l.owner_id
     where p_kind in ('first_call_pending', 'no_follow_up') and l.tenant_id = p_tenant and not coalesce(l.is_archived, false)
       and coalesce(s.kind, 'open') = 'open' and coalesce(l.temperature, '') not in ('not_interested', 'closed')
       and (p_business is null or l.business_id = p_business)
       and case p_kind
             when 'first_call_pending' then not exists (select 1 from public.follow_ups f where f.lead_id = l.id and f.status = 'done')
                                        and not exists (select 1 from public.calls c where c.lead_id = l.id)
             else not exists (select 1 from public.follow_ups f where f.lead_id = l.id and f.status = 'pending')
           end
    union all
    -- a caller's calls (Callyzer) in the dates; connected = with talk time
    select null, (select lo.id from lead_of lo where lo.p10 = right(regexp_replace(coalesce(t.client_number, ''), '\D', '', 'g'), 10) and lo.p10 <> '' limit 1),
           (select lo.name from lead_of lo where lo.p10 = right(regexp_replace(coalesce(t.client_number, ''), '\D', '', 'g'), 10) and lo.p10 <> '' limit 1),
           t.client_number, t.started_at, initcap(coalesce(t.call_type, 'call')),
           case when coalesce(t.duration_sec, 0) > 0 then floor(t.duration_sec / 60) || 'm ' || mod(t.duration_sec, 60) || 's' else 'not connected' end, null
      from public.callyzer_team_calls t, b
     where p_kind in ('calls', 'connected') and t.tenant_id = p_tenant and t.emp_number = p_emp
       and t.started_at >= b.d0 and t.started_at < b.d1 and (p_kind = 'calls' or t.duration_sec > 0)
    union all
    -- overdue invoice parts
    select ip.id, i.lead_id, coalesce(i.client_name, 'Invoice'), i.phone, ip.due_on::timestamp at time zone 'Asia/Kolkata',
           coalesce(i.invoice_no, 'Invoice') || ' · ' || coalesce(ip.label, 'Payment'), '₹' || to_char(ip.amount, 'FM99,99,99,999'), null
      from public.invoice_payments ip join public.invoices i on i.id = ip.invoice_id, b
     where p_kind = 'overdue_payments' and ip.tenant_id = p_tenant and ip.status = 'pending' and ip.due_on < b.today
       and (p_business is null or i.business_id = p_business)
  )
  select case when not exists (select 1 from b) then null else coalesce((
    select jsonb_agg(jsonb_build_object('key', coalesce(r.id::text, '') || coalesce(r.at_::text, ''), 'lead_id', r.lead_id, 'name', r.name, 'phone', r.phone,
             'at', r.at_, 'what', r.what, 'note', r.note, 'extra', r.extra) order by r.at_ desc nulls last)
      from r), '[]'::jsonb) end
$$;
revoke all on function public.owner_dash_records(uuid, date, date, text, uuid, text, uuid) from public, anon;
grant execute on function public.owner_dash_records(uuid, date, date, text, uuid, text, uuid) to authenticated;
