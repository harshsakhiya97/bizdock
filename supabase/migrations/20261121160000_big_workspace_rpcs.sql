-- Big workspaces (BGR: 22,000+ leads). The leads / purchases read policies run several lookups for every row
-- (about 3 ms a row), so listing everything timed out. These RPCs apply the same rules with the caller's access
-- worked out once per call. The tables' own policies are unchanged.

-- Leads page (paged, 1,000 at most per call). Same rule as "leads: read" (private.can_see_lead + private.can_access_sub).
create or replace function public.list_leads(p_tenant uuid, p_offset integer default 0, p_limit integer default 1000)
returns setof public.leads
language plpgsql stable security definer
set search_path to ''
as $function$
declare
  v_scope text;
  v_biz uuid[];
  v_team uuid[];
  v_me uuid;
  v_lim int := least(greatest(coalesce(p_limit, 1000), 1), 1000);
begin
  if private.is_platform_owner() then
    return query select * from public.leads l where l.tenant_id = p_tenant order by l.created_at desc, l.id offset greatest(p_offset, 0) limit v_lim;
    return;
  end if;
  v_scope := private.lead_scope(p_tenant);
  if v_scope is null or v_scope = 'none' then return; end if;
  select coalesce(array_agg(b.id), '{}') into v_biz from public.businesses b where b.tenant_id = p_tenant and private.can_access_business(b.id);
  v_me := private.my_member_id(p_tenant);
  if v_scope = 'team' then select coalesce(array_agg(x), '{}') into v_team from private.my_team(p_tenant) x; end if;
  return query
    select * from public.leads l
    where l.tenant_id = p_tenant
      and l.business_id = any (v_biz)
      and (l.sub_business_id is null or private.can_access_sub(l.business_id, l.sub_business_id))
      and case v_scope
        when 'all' then true
        when 'team' then l.owner_id is null or l.owner_id = any (v_team)
        when 'own' then l.owner_id = v_me
        else false
      end
    order by l.created_at desc, l.id
    offset greatest(p_offset, 0) limit v_lim;
end
$function$;
revoke all on function public.list_leads(uuid, integer, integer) from public;
grant execute on function public.list_leads(uuid, integer, integer) to authenticated;

-- Purchases with their payment parts and the lead's name / phone / email / city (Enrolled Courses, Upsell, Customers).
-- Same rules as "purchases: read"; lead details only for leads the caller may see.
create or replace function public.list_purchases(p_tenant uuid, p_offset integer default 0, p_limit integer default 1000)
returns setof jsonb
language plpgsql stable security definer
set search_path to ''
as $function$
declare
  v_owner boolean := private.is_platform_owner();
  v_scope text;
  v_biz uuid[];
  v_team uuid[];
  v_me uuid;
  v_lim int := least(greatest(coalesce(p_limit, 1000), 1), 1000);
begin
  if not v_owner and not private.is_member(p_tenant) then return; end if;
  v_scope := case when v_owner then 'all' else coalesce(private.lead_scope(p_tenant), 'none') end;
  select coalesce(array_agg(b.id), '{}') into v_biz from public.businesses b where b.tenant_id = p_tenant and (v_owner or private.can_access_business(b.id));
  v_me := private.my_member_id(p_tenant);
  if v_scope = 'team' then select coalesce(array_agg(x), '{}') into v_team from private.my_team(p_tenant) x; end if;
  return query
    select to_jsonb(p) || jsonb_build_object(
      'purchase_payments', coalesce((select jsonb_agg(to_jsonb(x)) from public.purchase_payments x where x.purchase_id = p.id), '[]'::jsonb),
      'leads', case when l.id is not null and (
                  v_scope = 'all'
                  or (v_scope = 'team' and (l.owner_id is null or l.owner_id = any (v_team)))
                  or (v_scope = 'own' and l.owner_id = v_me))
               then jsonb_build_object('first_name', l.first_name, 'last_name', l.last_name, 'phone', l.phone, 'email', l.email, 'city', l.city) end)
    from public.purchases p
    left join public.leads l on l.id = p.lead_id
    where p.tenant_id = p_tenant and p.business_id = any (v_biz)
    order by p.purchase_date desc, p.id
    offset greatest(p_offset, 0) limit v_lim;
end
$function$;
revoke all on function public.list_purchases(uuid, integer, integer) from public;
grant execute on function public.list_purchases(uuid, integer, integer) to authenticated;

-- Workflow builder pickers: tag names and extra-field names per funnel (names only, members of the workspace).
create or replace function public.lead_tag_field_names(p_tenant uuid)
returns jsonb
language plpgsql stable security definer
set search_path to ''
as $function$
begin
  if not (private.is_member(p_tenant) or private.is_platform_owner()) then return '{}'::jsonb; end if;
  return jsonb_build_object(
    'tags', coalesce((select jsonb_agg(distinct t) from public.leads l cross join unnest(l.tags) t where l.tenant_id = p_tenant), '[]'::jsonb),
    'extras', coalesce((select jsonb_agg(jsonb_build_object('funnel_id', f, 'keys', k)) from (
        select l.funnel_id f, jsonb_agg(distinct e.key) k
        from public.leads l cross join jsonb_object_keys(l.extra) e(key)
        where l.tenant_id = p_tenant and l.extra <> '{}'::jsonb
        group by l.funnel_id) s), '[]'::jsonb)
  );
end
$function$;
revoke all on function public.lead_tag_field_names(uuid) from public;
grant execute on function public.lead_tag_field_names(uuid) to authenticated;
