-- Follow-ups / My Day / dashboards: every follow-up of the workspace with its lead, in pages of up to 1,000.
-- Same access as the follow_ups table (the lead can be seen) and its embedded lead (and its sub-business), but
-- checked once per call instead of per row: the table read took ~7 s for 2,500 follow-ups (and stopped at 1,000).
create or replace function public.list_follow_ups(p_tenant uuid, p_offset integer default 0, p_limit integer default 1000)
returns setof jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_all boolean := private.is_platform_owner();
  v_scope text;
  v_biz uuid[];
  v_team uuid[];
  v_me uuid;
  v_lim int := least(greatest(coalesce(p_limit, 1000), 1), 1000);
begin
  if not v_all then
    v_scope := private.lead_scope(p_tenant);
    if v_scope is null or v_scope = 'none' then return; end if;
    select coalesce(array_agg(b.id), '{}') into v_biz from public.businesses b where b.tenant_id = p_tenant and private.can_access_business(b.id);
    v_me := private.my_member_id(p_tenant);
    if v_scope = 'team' then select coalesce(array_agg(x), '{}') into v_team from private.my_team(p_tenant) x; end if;
  end if;
  return query
    with seen as (
      select l.* from public.leads l
       where l.tenant_id = p_tenant
         and (v_all or (l.business_id = any (v_biz)
              and case v_scope
                    when 'all' then true
                    when 'team' then l.owner_id is null or l.owner_id = any (v_team)
                    when 'own' then l.owner_id = v_me
                    else false
                  end))
    )
    select to_jsonb(f) || jsonb_build_object('leads',
             case when v_all or l.sub_business_id is null or private.can_access_sub(l.business_id, l.sub_business_id) then
               jsonb_build_object('id', l.id, 'first_name', l.first_name, 'last_name', l.last_name, 'phone', l.phone, 'whatsapp', l.whatsapp,
                 'business_id', l.business_id, 'sub_business_id', l.sub_business_id, 'funnel_id', l.funnel_id, 'stage_id', l.stage_id,
                 'owner_id', l.owner_id, 'purpose', l.purpose, 'required_on', l.required_on, 'temperature', l.temperature)
             end)
      from public.follow_ups f join seen l on l.id = f.lead_id
     where f.tenant_id = p_tenant
     order by f.due_at, f.id
     offset greatest(p_offset, 0) limit v_lim;
end $$;
revoke all on function public.list_follow_ups(uuid, integer, integer) from public, anon;
grant execute on function public.list_follow_ups(uuid, integer, integer) to authenticated;
