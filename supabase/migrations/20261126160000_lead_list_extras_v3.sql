-- Lead list extras (last comment, follow-ups done, connected calls, meeting) — faster:
--  * p_funnel: the funnel Leads tab asks only for that funnel's leads (was: every lead in the workspace)
--  * the sub-business check is done once per sub-business, not once per lead
--  * connected calls are looked up by the leads' numbers (index calls_tenant_phone)
-- lead_list_extras_v2 stays (old open browsers) and now uses the same code.
create or replace function public.lead_list_extras_v3(p_tenant uuid, p_sub uuid default null, p_funnel uuid default null)
returns table(lead_id uuid, last_note text, last_note_at timestamptz, fu_done integer, connected integer, pending_fu_id uuid,
              meeting_status text, meeting_link text, meeting_date date, meeting_time time)
language plpgsql stable security definer set search_path = '' as $$
declare
  v_all boolean := private.is_platform_owner();
  v_scope text;
  v_biz uuid[];
  v_subs uuid[];
  v_team uuid[];
  v_me uuid;
  v_ids uuid[];
  v_phs text[];
  v_member boolean := private.is_member(p_tenant);
  v_meet boolean := private.has_permission(p_tenant, 'meetings', 'view');
begin
  v_scope := case when v_all then 'all' else coalesce(private.lead_scope(p_tenant), 'none') end;
  if v_scope = 'none' then return; end if;
  select coalesce(array_agg(b.id), '{}') into v_biz from public.businesses b
   where b.tenant_id = p_tenant and (v_all or private.can_access_business(b.id));
  select coalesce(array_agg(s.id), '{}') into v_subs from public.sub_businesses s
   where s.business_id = any (v_biz) and (v_all or private.can_access_sub(s.business_id, s.id));
  v_me := private.my_member_id(p_tenant);
  if v_scope = 'team' then select coalesce(array_agg(x), '{}') into v_team from private.my_team(p_tenant) x; end if;
  -- the leads first (ids and 10-digit numbers), then each table looked up by index with = any(...)
  select coalesce(array_agg(l.id), '{}'),
         coalesce(array_agg(distinct right(regexp_replace(coalesce(l.phone, ''), '\D', '', 'g'), 10))
                  filter (where coalesce(l.phone, '') <> ''), '{}')
    into v_ids, v_phs
    from public.leads l
   where l.tenant_id = p_tenant
     and (p_sub is null or l.sub_business_id = p_sub)
     and (p_funnel is null or l.funnel_id = p_funnel)
     and l.business_id = any (v_biz)
     and (l.sub_business_id is null or l.sub_business_id = any (v_subs))
     and case v_scope
       when 'all' then true
       when 'team' then l.owner_id is null or l.owner_id = any (v_team)
       when 'own' then l.owner_id = v_me
       else false
     end;
  if cardinality(v_ids) = 0 then return; end if;
  if not v_member then v_phs := '{}'; end if;
  return query
  with n as (
    select distinct on (a.lead_id) a.lead_id, a.note, a.created_at
      from public.lead_activities a
     where a.lead_id = any (v_ids) and a.kind = 'note' and coalesce(a.note, '') <> ''
     order by a.lead_id, a.created_at desc
  ), f as (
    select fu.lead_id,
           count(*) filter (where fu.status = 'done') as done,
           (array_agg(fu.id order by fu.due_at) filter (where fu.status = 'pending'))[1] as pending_id
      from public.follow_ups fu
     where fu.lead_id = any (v_ids)
     group by fu.lead_id
  ), c as (
    select k.phone, count(*) as connected
      from public.calls k
     where k.tenant_id = p_tenant and k.phone = any (v_phs) and coalesce(k.duration_sec, 0) > 0
     group by k.phone
  ), m as (
    select distinct on (mt.lead_id) mt.lead_id, mt.status, mt.link, mt.meeting_date, mt.start_time
      from public.meetings mt
     where v_meet and mt.lead_id = any (v_ids)
     order by mt.lead_id, mt.meeting_date desc, mt.start_time desc
  ), l as (
    select x.id, right(regexp_replace(coalesce(x.phone, ''), '\D', '', 'g'), 10) as ph
      from public.leads x where x.id = any (v_ids)
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
$$;
revoke all on function public.lead_list_extras_v3(uuid, uuid, uuid) from public, anon;
grant execute on function public.lead_list_extras_v3(uuid, uuid, uuid) to authenticated;

create or replace function public.lead_list_extras_v2(p_tenant uuid, p_sub uuid)
returns table(lead_id uuid, last_note text, last_note_at timestamptz, fu_done integer, connected integer, pending_fu_id uuid,
              meeting_status text, meeting_link text, meeting_date date, meeting_time time)
language sql stable security definer set search_path = '' as $$
  select * from public.lead_list_extras_v3(p_tenant, p_sub, null)
$$;
