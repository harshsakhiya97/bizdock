-- New version of lead_list_extras (that one is unchanged): same output and the same lead access rule
-- (private.can_see_lead + private.can_access_sub), with the caller's access worked out once per call, and only leads
-- that have something to show (the app treats a missing lead as "nothing yet").
create or replace function public.lead_list_extras_v2(p_tenant uuid, p_sub uuid)
returns table(lead_id uuid, last_note text, last_note_at timestamp with time zone, fu_done integer, connected integer, pending_fu_id uuid,
              meeting_status text, meeting_link text, meeting_date date, meeting_time time without time zone)
language plpgsql stable security definer
set search_path to ''
as $function$
declare
  v_all boolean := private.is_platform_owner();
  v_scope text;
  v_biz uuid[];
  v_team uuid[];
  v_me uuid;
  v_member boolean := private.is_member(p_tenant);
  v_meet boolean := private.has_permission(p_tenant, 'meetings', 'view');
begin
  v_scope := case when v_all then 'all' else coalesce(private.lead_scope(p_tenant), 'none') end;
  if v_scope = 'none' then return; end if;
  select coalesce(array_agg(b.id), '{}') into v_biz from public.businesses b where b.tenant_id = p_tenant and (v_all or private.can_access_business(b.id));
  v_me := private.my_member_id(p_tenant);
  if v_scope = 'team' then select coalesce(array_agg(x), '{}') into v_team from private.my_team(p_tenant) x; end if;
  return query
  with l as (
    select l.id, right(regexp_replace(coalesce(l.phone, ''), '\D', '', 'g'), 10) as ph
      from public.leads l
     where l.tenant_id = p_tenant and (p_sub is null or l.sub_business_id = p_sub)
       and l.business_id = any (v_biz)
       and (l.sub_business_id is null or v_all or private.can_access_sub(l.business_id, l.sub_business_id))
       and case v_scope
         when 'all' then true
         when 'team' then l.owner_id is null or l.owner_id = any (v_team)
         when 'own' then l.owner_id = v_me
         else false
       end
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
     where v_member and k.tenant_id = p_tenant and coalesce(k.duration_sec, 0) > 0
       and k.phone in (select ph from l)
     group by k.phone
  ), m as (
    select distinct on (mt.lead_id) mt.lead_id, mt.status, mt.link, mt.meeting_date, mt.start_time
      from public.meetings mt join l on l.id = mt.lead_id
     where v_meet
     order by mt.lead_id, mt.meeting_date desc, mt.start_time desc
  )
  select l.id, n.note, n.created_at, coalesce(f.done, 0)::int, coalesce(c.connected, 0)::int, f.pending_id,
         m.status, m.link, m.meeting_date, m.start_time
    from l
    left join n on n.lead_id = l.id
    left join f on f.lead_id = l.id
    left join c on c.phone = l.ph
    left join m on m.lead_id = l.id
   where n.lead_id is not null or f.lead_id is not null or c.phone is not null or m.lead_id is not null;
end
$function$;
revoke all on function public.lead_list_extras_v2(uuid, uuid) from public;
grant execute on function public.lead_list_extras_v2(uuid, uuid) to authenticated;
