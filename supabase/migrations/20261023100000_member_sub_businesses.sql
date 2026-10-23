-- Sub-business access per member: member_businesses.sub_business_ids
-- (null / empty = every sub-business of that business; records without a sub-business stay visible).
alter table public.member_businesses add column if not exists sub_business_ids uuid[];

create or replace function private.can_access_sub(b uuid, s uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select s is null or private.is_platform_owner() or exists (
    select 1
    from public.businesses bz
    join public.tenant_members m on m.tenant_id = bz.tenant_id
    where bz.id = b and m.user_id = (select auth.uid()) and m.status = 'active'
      and (m.all_businesses
           or exists (select 1 from public.member_businesses mb
                      where mb.member_id = m.id and mb.business_id = b
                        and (coalesce(cardinality(mb.sub_business_ids), 0) = 0 or s = any (mb.sub_business_ids))))
  )
$$;
grant execute on function private.can_access_sub(uuid, uuid) to authenticated;

-- leads
alter policy "leads: read" on public.leads
  using (private.can_see_lead(tenant_id, business_id, owner_id) and private.can_access_sub(business_id, sub_business_id));
alter policy "leads: update" on public.leads
  using (private.can_see_lead(tenant_id, business_id, owner_id) and private.can_access_sub(business_id, sub_business_id)
         and (private.has_permission(tenant_id, 'leads', 'edit') or private.has_permission(tenant_id, 'leads', 'assign')
              or private.has_permission(tenant_id, 'follow_ups', 'add') or private.has_permission(tenant_id, 'leads', 'delete')))
  with check (private.can_access_business(business_id) and private.can_access_sub(business_id, sub_business_id));
alter policy "leads: insert" on public.leads
  with check (private.has_permission(tenant_id, 'leads', 'add') and private.can_access_business(business_id) and private.can_access_sub(business_id, sub_business_id));
alter policy "leads: delete" on public.leads
  using (private.can_see_lead(tenant_id, business_id, owner_id) and private.can_access_sub(business_id, sub_business_id) and private.has_permission(tenant_id, 'leads', 'delete'));

-- bookings (and their items / payment parts through can_see_booking)
alter policy "bookings: read" on public.bookings
  using (private.can_see_owned(tenant_id, business_id, owner_id, 'sales') and private.can_access_sub(business_id, sub_business_id));
alter policy "bookings: update" on public.bookings
  using (private.has_permission(tenant_id, 'bookings', 'edit') and private.can_see_owned(tenant_id, business_id, owner_id, 'sales') and private.can_access_sub(business_id, sub_business_id))
  with check (private.can_access_business(business_id) and private.can_access_sub(business_id, sub_business_id));
alter policy "bookings: insert" on public.bookings
  with check (private.has_permission(tenant_id, 'bookings', 'add') and private.can_access_business(business_id) and private.can_access_sub(business_id, sub_business_id));

create or replace function private.can_see_booking(bk uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.bookings b where b.id = bk
                 and private.can_see_owned(b.tenant_id, b.business_id, b.owner_id, 'sales')
                 and private.can_access_sub(b.business_id, b.sub_business_id))
$$;

-- funnels of a sub-business the member can't open
alter policy "funnels: read" on public.funnels
  using ((private.can_access_business(business_id) and private.can_access_sub(business_id, sub_business_id))
         or private.has_permission(tenant_id, 'funnels', 'view'));
