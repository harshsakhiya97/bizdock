-- Meetings (Paid Podcast): a meeting with the guest (lead) to decide if they qualify.
-- Qualified → book the podcast; Not qualified → the lead is dropped (moved to its funnel's Lost stage).
create table public.meetings (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  business_id uuid not null references public.businesses(id) on delete cascade,
  sub_business_id uuid references public.sub_businesses(id) on delete set null,
  lead_id uuid not null references public.leads(id) on delete cascade,
  meeting_date date not null,
  start_time time not null,
  end_time time not null,
  mode text not null default 'online' check (mode in ('online', 'in_person')),
  link text,
  location text,
  status text not null default 'scheduled' check (status in ('scheduled', 'qualified', 'not_qualified', 'no_show', 'cancelled')),
  outcome_note text,
  -- earlier slots: [{date, start, end, reason, at, by}]
  reschedules jsonb not null default '[]'::jsonb,
  created_by uuid references public.tenant_members(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint meetings_time check (end_time > start_time)
);
create index meetings_tenant_date on public.meetings (tenant_id, meeting_date);
create index meetings_lead on public.meetings (lead_id);

create trigger meetings_set_updated_at before update on public.meetings
  for each row execute function public.set_updated_at();

alter table public.meetings enable row level security;

create policy "meetings: read" on public.meetings for select to authenticated
  using (private.has_permission(tenant_id, 'meetings', 'view')
         and private.can_access_sub(business_id, sub_business_id)
         and exists (select 1 from public.leads l where l.id = lead_id and private.can_see_lead(l.tenant_id, l.business_id, l.owner_id)));
create policy "meetings: insert" on public.meetings for insert to authenticated
  with check (private.has_permission(tenant_id, 'meetings', 'add')
              and private.can_access_business(business_id) and private.can_access_sub(business_id, sub_business_id)
              and exists (select 1 from public.leads l where l.id = lead_id and l.tenant_id = meetings.tenant_id and private.can_see_lead(l.tenant_id, l.business_id, l.owner_id)));
create policy "meetings: update" on public.meetings for update to authenticated
  using (private.has_permission(tenant_id, 'meetings', 'edit')
         and private.can_access_sub(business_id, sub_business_id)
         and exists (select 1 from public.leads l where l.id = lead_id and private.can_see_lead(l.tenant_id, l.business_id, l.owner_id)))
  with check (private.can_access_business(business_id) and private.can_access_sub(business_id, sub_business_id));
create policy "meetings: delete" on public.meetings for delete to authenticated
  using (private.has_permission(tenant_id, 'meetings', 'delete')
         and private.can_access_sub(business_id, sub_business_id));

-- Not qualified → drop the lead: move it to its funnel's Lost stage (when it has a funnel with one)
create or replace function private.meeting_drop_lead()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_lost uuid;
begin
  if new.status = 'not_qualified' and (tg_op = 'INSERT' or old.status is distinct from 'not_qualified') then
    select s.id into v_lost
      from public.leads l join public.funnel_stages s on s.funnel_id = l.funnel_id and s.kind = 'lost'
     where l.id = new.lead_id
     order by s.sort_order limit 1;
    if v_lost is not null then
      update public.leads set stage_id = v_lost, stage_changed_at = now()
       where id = new.lead_id and stage_id is distinct from v_lost;
    end if;
  end if;
  return new;
end $$;

create trigger meetings_drop_lead after insert or update of status on public.meetings
  for each row execute function private.meeting_drop_lead();
