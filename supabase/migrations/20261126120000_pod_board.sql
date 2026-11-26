-- Paid Podcast → Leads / Customers board: what each lead the caller can see has done — follow-up calls done, meetings
-- (booked / done / no-show, next or last date), the podcast shoot (a booking: next or last date) and its money.
-- The access is checked once (like list_follow_ups), not per row.
create or replace function public.pod_board(p_tenant uuid)
returns table(lead_id uuid, fu_done int, m_booked boolean, m_done boolean, m_noshow boolean, meeting_on date,
              shoot boolean, shoot_on date, billed numeric, paid numeric)
language plpgsql stable security definer set search_path = '' as $$
declare
  v_all boolean := private.is_platform_owner();
  v_scope text;
  v_biz uuid[];
  v_team uuid[];
  v_me uuid;
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
      select l.id from public.leads l
       where l.tenant_id = p_tenant
         and (v_all or (l.business_id = any (v_biz)
              and (l.sub_business_id is null or private.can_access_sub(l.business_id, l.sub_business_id))
              and case v_scope
                    when 'all' then true
                    when 'team' then l.owner_id is null or l.owner_id = any (v_team)
                    when 'own' then l.owner_id = v_me
                    else false
                  end))
    ),
    f as (
      select fu.lead_id, count(*)::int n from public.follow_ups fu join seen on seen.id = fu.lead_id
       where fu.tenant_id = p_tenant and fu.status = 'done' group by fu.lead_id
    ),
    m as (
      select mt.lead_id, bool_or(mt.status <> 'cancelled') booked, bool_or(mt.status = 'done') done, bool_or(mt.status = 'no_show') noshow,
             coalesce(min(mt.meeting_date) filter (where mt.status <> 'cancelled' and mt.meeting_date >= current_date),
                      max(mt.meeting_date) filter (where mt.status <> 'cancelled')) d
        from public.meetings mt join seen on seen.id = mt.lead_id
       where mt.tenant_id = p_tenant group by mt.lead_id
    ),
    b as (
      select bk.lead_id, coalesce(min(bk.booking_date) filter (where bk.booking_date >= current_date), max(bk.booking_date)) d,
             sum(coalesce(bk.total_amount, 0)) billed, sum(coalesce(bk.paid_amount, 0)) paid
        from public.bookings bk join seen on seen.id = bk.lead_id
       where bk.tenant_id = p_tenant and bk.status <> 'cancelled' group by bk.lead_id
    )
    select s.id, coalesce(f.n, 0), coalesce(m.booked, false), coalesce(m.done, false), coalesce(m.noshow, false), m.d,
           b.lead_id is not null, b.d, coalesce(b.billed, 0), coalesce(b.paid, 0)
      from seen s left join f on f.lead_id = s.id left join m on m.lead_id = s.id left join b on b.lead_id = s.id
     where f.lead_id is not null or m.lead_id is not null or b.lead_id is not null;
end $$;
revoke all on function public.pod_board(uuid) from public, anon;
grant execute on function public.pod_board(uuid) to authenticated;
