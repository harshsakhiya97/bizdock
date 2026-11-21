-- Leads page cards in one quick call (shown before the full list has loaded): total, new this week, follow-ups due /
-- overdue, won and the count per category. Same lead access rule as list_leads (worked out once per call);
-- not-archived leads of the business / sub-business picked in the top bar.
create or replace function public.lead_stats(p_tenant uuid, p_business uuid default null, p_sub uuid default null)
returns jsonb
language plpgsql stable security definer
set search_path to ''
as $function$
declare
  v_all boolean := private.is_platform_owner();
  v_scope text;
  v_biz uuid[];
  v_team uuid[];
  v_me uuid;
  v_end_today timestamptz := (date_trunc('day', now() at time zone 'Asia/Kolkata') + interval '1 day') at time zone 'Asia/Kolkata';
  res jsonb;
begin
  v_scope := case when v_all then 'all' else coalesce(private.lead_scope(p_tenant), 'none') end;
  if v_scope = 'none' then return '{}'::jsonb; end if;
  select coalesce(array_agg(b.id), '{}') into v_biz from public.businesses b
   where b.tenant_id = p_tenant and (p_business is null or b.id = p_business) and (v_all or private.can_access_business(b.id));
  v_me := private.my_member_id(p_tenant);
  if v_scope = 'team' then select coalesce(array_agg(x), '{}') into v_team from private.my_team(p_tenant) x; end if;
  with l as (
    select l.temperature, l.created_at, l.next_follow_up_at, l.stage_id
      from public.leads l
     where l.tenant_id = p_tenant and not l.is_archived
       and l.business_id = any (v_biz)
       and (p_sub is null or l.sub_business_id = p_sub)
       and (l.sub_business_id is null or v_all or private.can_access_sub(l.business_id, l.sub_business_id))
       and case v_scope
         when 'all' then true
         when 'team' then l.owner_id is null or l.owner_id = any (v_team)
         when 'own' then l.owner_id = v_me
         else false
       end
  )
  select jsonb_build_object(
    'total', count(*),
    'new_week', count(*) filter (where l.created_at >= now() - interval '7 days'),
    'due', count(*) filter (where l.next_follow_up_at < v_end_today),
    'overdue', count(*) filter (where l.next_follow_up_at < now()),
    'won', count(*) filter (where exists (select 1 from public.funnel_stages s where s.id = l.stage_id and s.kind = 'won')),
    'temps', jsonb_build_object(
      'new', count(*) filter (where l.temperature = 'new'), 'hot', count(*) filter (where l.temperature = 'hot'),
      'warm', count(*) filter (where l.temperature = 'warm'), 'cold', count(*) filter (where l.temperature = 'cold'),
      'not_interested', count(*) filter (where l.temperature = 'not_interested'), 'closed', count(*) filter (where l.temperature = 'closed'),
      'none', count(*) filter (where l.temperature is null))
  ) into res from l;
  return res;
end
$function$;
revoke all on function public.lead_stats(uuid, uuid, uuid) from public;
grant execute on function public.lead_stats(uuid, uuid, uuid) to authenticated;
