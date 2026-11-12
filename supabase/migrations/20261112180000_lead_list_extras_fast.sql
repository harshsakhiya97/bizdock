-- lead_list_extras was too slow as the caller (each lead's activities / follow-ups / calls checked row by row against the
-- access rules → statement timeout). Now: the caller's access is checked once per lead (the same rules as the leads list),
-- and the rest is counted in one pass per table.
create or replace function public.lead_list_extras(p_tenant uuid, p_sub uuid)
returns table (
  lead_id uuid,
  last_note text,
  last_note_at timestamptz,
  fu_done int,
  connected int,
  pending_fu_id uuid,
  meeting_status text,
  meeting_link text,
  meeting_date date,
  meeting_time time
)
language sql stable security definer set search_path = '' as $$
  with l as (
    select l.id, right(regexp_replace(coalesce(l.phone, ''), '\D', '', 'g'), 10) as ph
      from public.leads l
     where l.tenant_id = p_tenant and l.sub_business_id = p_sub
       and private.can_see_lead(l.tenant_id, l.business_id, l.owner_id)
       and private.can_access_sub(l.business_id, l.sub_business_id)
  ), n as (
    select distinct on (a.lead_id) a.lead_id, a.note, a.created_at
      from public.lead_activities a join l on l.id = a.lead_id
     where a.kind = 'note' and coalesce(a.note, '') <> ''
     order by a.lead_id, a.created_at desc
  ), f as (
    select fu.lead_id,
           count(*) filter (where fu.status = 'done') as done,
           (array_agg(fu.id order by fu.due_at) filter (where fu.status = 'pending'))[1] as pending_id
      from public.follow_ups fu join l on l.id = fu.lead_id
     group by fu.lead_id
  ), c as (
    select k.phone, count(*) as connected
      from public.calls k
     where k.tenant_id = p_tenant and coalesce(k.duration_sec, 0) > 0 and private.is_member(p_tenant)
       and k.phone in (select ph from l)
     group by k.phone
  ), m as (
    select distinct on (mt.lead_id) mt.lead_id, mt.status, mt.link, mt.meeting_date, mt.start_time
      from public.meetings mt join l on l.id = mt.lead_id
     where private.has_permission(p_tenant, 'meetings', 'view')
     order by mt.lead_id, mt.meeting_date desc, mt.start_time desc
  )
  select l.id, n.note, n.created_at, coalesce(f.done, 0)::int, coalesce(c.connected, 0)::int, f.pending_id,
         m.status, m.link, m.meeting_date, m.start_time
    from l
    left join n on n.lead_id = l.id
    left join f on f.lead_id = l.id
    left join c on c.phone = l.ph
    left join m on m.lead_id = l.id;
$$;
revoke all on function public.lead_list_extras(uuid, uuid) from public, anon;
grant execute on function public.lead_list_extras(uuid, uuid) to authenticated;
