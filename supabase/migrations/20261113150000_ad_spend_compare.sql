-- A funnel's saved day-wise ad spend (old CRM / typed in) next to Facebook's numbers of its linked campaigns, and
-- Replace: the saved days Facebook has numbers for take Facebook's spend (without GST), marked source 'meta'.
create or replace function public.ad_spend_compare(p_funnel uuid) returns table (day date, saved numeric, meta numeric, source text)
language sql stable security definer set search_path = '' as $$
  select s.spend_date, s.amount,
         (select sum(i.spend) from public.meta_insights i
           where i.tenant_id = s.tenant_id and i.day = s.spend_date
             and exists (select 1 from public.funnel_ad_links l where l.funnel_id = s.funnel_id and l.campaign_id = i.campaign_id and (l.adset_id is null or l.adset_id = i.adset_id))),
         s.source
    from public.ad_spend s join public.funnels f on f.id = s.funnel_id
   where s.funnel_id = p_funnel and private.has_permission(f.tenant_id, 'funnels', 'view')
   order by s.spend_date
$$;
revoke all on function public.ad_spend_compare(uuid) from public, anon;
grant execute on function public.ad_spend_compare(uuid) to authenticated;

create or replace function public.ad_spend_replace(p_funnel uuid) returns int
language plpgsql security definer set search_path = '' as $$
declare
  f public.funnels;
  n int;
begin
  select * into f from public.funnels where id = p_funnel;
  if f.id is null or not private.has_permission(f.tenant_id, 'funnels', 'edit') then raise exception 'You need funnel edit access.'; end if;
  -- the saved amount is kept in the notes
  update public.ad_spend s set amount = c.meta, source = 'meta', updated_at = now(),
         notes = btrim(concat_ws(' · ', nullif(s.notes, ''), 'Before Facebook: ' || s.amount::text || ' (' || s.source || ')'))
    from public.ad_spend_compare(p_funnel) c
   where s.funnel_id = p_funnel and s.spend_date = c.day and c.meta is not null and s.source <> 'meta';
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.ad_spend_replace(uuid) from public, anon;
grant execute on function public.ad_spend_replace(uuid) to authenticated;
