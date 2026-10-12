-- ============================================================
-- Leads: a lead belongs to a business, sits in one funnel stage, has an owner.
-- Who sees a lead follows the person's "Leads" visibility (Access Control):
--   all  = every lead of the businesses they work in
--   team = leads owned by them or anyone reporting to them (directly or below), plus unassigned
--   own  = leads they own
--   none = no leads
-- Deleting in the app = archiving (with a reason); data is kept.
-- ============================================================

-- ---------- masters (per client, editable later in Masters) ----------
create table public.lead_sources (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenants (id) on delete cascade,
  name        text not null,
  is_active   boolean not null default true,
  sort_order  int not null default 0,
  created_at  timestamptz not null default now(),
  unique (tenant_id, name)
);

create table public.lost_reasons (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenants (id) on delete cascade,
  name        text not null,
  is_active   boolean not null default true,
  sort_order  int not null default 0,
  created_at  timestamptz not null default now(),
  unique (tenant_id, name)
);

create or replace function private.seed_tenant_masters(t uuid)
returns void language sql security definer set search_path = '' as $$
  insert into public.lead_sources (tenant_id, name, sort_order)
  select t, s.name, s.ord from unnest(array[
    'Facebook','Instagram','YouTube','Google','Website','WhatsApp','Referral','Affiliate',
    'Telecalling','Incoming call','Email','SMS','LinkedIn','Event','Walk-in','Direct','Other'
  ]) with ordinality as s(name, ord)
  on conflict do nothing;
  insert into public.lost_reasons (tenant_id, name, sort_order)
  select t, s.name, s.ord from unnest(array[
    'Budget issue','Not interested','Bought elsewhere','Not reachable','Wrong number','Future reference','Other'
  ]) with ordinality as s(name, ord)
  on conflict do nothing;
$$;

create or replace function private.seed_new_tenant_masters()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform private.seed_tenant_masters(new.id);
  return new;
end;
$$;
create trigger tenants_seed_masters after insert on public.tenants
  for each row execute function private.seed_new_tenant_masters();

-- existing clients
select private.seed_tenant_masters(id) from public.tenants;

-- ---------- leads ----------
create table public.leads (
  id                 uuid primary key default gen_random_uuid(),
  tenant_id          uuid not null references public.tenants (id) on delete cascade,
  business_id        uuid not null,
  funnel_id          uuid not null,
  stage_id           uuid not null references public.funnel_stages (id),
  first_name         text not null,
  last_name          text,
  phone              text not null,
  whatsapp           text,
  email              text,
  city               text,
  source_id          uuid references public.lead_sources (id) on delete set null,
  referred_by        text,
  temperature        text check (temperature in ('hot', 'warm', 'cold', 'not_interested')),
  estimated_amount   numeric(12, 2),
  owner_id           uuid references public.tenant_members (id) on delete set null,
  tags               text[] not null default '{}',
  notes              text,
  next_follow_up_at  timestamptz,
  lost_reason_id     uuid references public.lost_reasons (id) on delete set null,
  is_archived        boolean not null default false,
  archive_reason     text,
  archived_at        timestamptz,
  stage_changed_at   timestamptz not null default now(),
  created_by         uuid references public.tenant_members (id) on delete set null,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  foreign key (business_id, tenant_id) references public.businesses (id, tenant_id) on delete cascade,
  foreign key (funnel_id, business_id) references public.funnels (id, business_id) on delete cascade
);
create index leads_tenant_idx on public.leads (tenant_id, created_at desc);
create index leads_funnel_stage_idx on public.leads (funnel_id, stage_id);
create index leads_owner_idx on public.leads (owner_id);
create index leads_business_phone_idx on public.leads (business_id, phone);
create index leads_follow_up_idx on public.leads (tenant_id, next_follow_up_at);
create trigger leads_set_updated_at before update on public.leads
  for each row execute function public.set_updated_at();

-- the stage must belong to the lead's funnel; keep stage_changed_at current
create or replace function private.check_lead_stage()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.funnel_stages s where s.id = new.stage_id and s.funnel_id = new.funnel_id) then
    raise exception 'That stage is not part of this funnel';
  end if;
  if tg_op = 'UPDATE' and new.stage_id is distinct from old.stage_id then
    new.stage_changed_at := now();
  end if;
  return new;
end;
$$;
create trigger leads_check_stage before insert or update on public.leads
  for each row execute function private.check_lead_stage();

-- ---------- activity (history + notes) ----------
create table public.lead_activities (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references public.tenants (id) on delete cascade,
  lead_id        uuid not null references public.leads (id) on delete cascade,
  kind           text not null check (kind in ('created', 'stage', 'note', 'assigned', 'temperature', 'follow_up', 'archived', 'restored')),
  from_stage_id  uuid references public.funnel_stages (id) on delete set null,
  to_stage_id    uuid references public.funnel_stages (id) on delete set null,
  note           text,
  member_id      uuid references public.tenant_members (id) on delete set null,
  created_at     timestamptz not null default now()
);
create index lead_activities_lead_idx on public.lead_activities (lead_id, created_at desc);

-- ============================================================
-- Visibility helpers
-- ============================================================

-- the caller's member id in a tenant
create or replace function private.my_member_id(t uuid)
returns uuid language sql stable security definer set search_path = '' as $$
  select id from public.tenant_members
  where tenant_id = t and user_id = (select auth.uid()) and status = 'active'
$$;

-- the caller's "leads" visibility: all / team / own / none
create or replace function private.lead_scope(t uuid)
returns text language sql stable security definer set search_path = '' as $$
  select case
    when private.is_platform_owner() then 'all'
    else (
      select case
        when r.is_system or r.level <= 1 then 'all'
        else coalesce(coalesce(m.permissions, r.permissions) -> 'scope' ->> 'leads', 'none')
      end
      from public.tenant_members m join public.roles r on r.id = m.role_id
      where m.tenant_id = t and m.user_id = (select auth.uid()) and m.status = 'active'
    )
  end
$$;

-- the caller and everyone who reports to them, at any depth
create or replace function private.my_team(t uuid)
returns setof uuid language sql stable security definer set search_path = '' as $$
  with recursive tree as (
    select id from public.tenant_members where tenant_id = t and user_id = (select auth.uid())
    union
    select m.id from public.tenant_members m join tree on m.reports_to = tree.id
  )
  select id from tree
$$;

create or replace function private.can_see_lead(t uuid, b uuid, owner uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select private.can_access_business(b) and case private.lead_scope(t)
    when 'all'  then true
    when 'team' then owner is null or owner in (select private.my_team(t))
    when 'own'  then owner = private.my_member_id(t)
    else false
  end
$$;

revoke execute on all functions in schema private from public, anon;
grant execute on all functions in schema private to authenticated;

-- ============================================================
-- Row security
-- ============================================================
alter table public.lead_sources enable row level security;
create policy "lead_sources: read" on public.lead_sources for select to authenticated
  using (private.is_member(tenant_id) or private.is_platform_owner());
create policy "lead_sources: write" on public.lead_sources for all to authenticated
  using (private.has_permission(tenant_id, 'masters', 'edit'))
  with check (private.has_permission(tenant_id, 'masters', 'edit'));

alter table public.lost_reasons enable row level security;
create policy "lost_reasons: read" on public.lost_reasons for select to authenticated
  using (private.is_member(tenant_id) or private.is_platform_owner());
create policy "lost_reasons: write" on public.lost_reasons for all to authenticated
  using (private.has_permission(tenant_id, 'masters', 'edit'))
  with check (private.has_permission(tenant_id, 'masters', 'edit'));

alter table public.leads enable row level security;
create policy "leads: read" on public.leads for select to authenticated
  using (private.can_see_lead(tenant_id, business_id, owner_id));
create policy "leads: insert" on public.leads for insert to authenticated
  with check (private.has_permission(tenant_id, 'leads', 'add') and private.can_access_business(business_id));
-- edit fields / move stage (leads.edit), change owner (leads.assign), schedule follow-ups, archive (leads.delete)
create policy "leads: update" on public.leads for update to authenticated
  using (private.can_see_lead(tenant_id, business_id, owner_id)
         and (private.has_permission(tenant_id, 'leads', 'edit') or private.has_permission(tenant_id, 'leads', 'assign')
              or private.has_permission(tenant_id, 'follow_ups', 'add') or private.has_permission(tenant_id, 'leads', 'delete')))
  with check (private.can_access_business(business_id));

alter table public.lead_activities enable row level security;
create policy "lead_activities: read" on public.lead_activities for select to authenticated
  using (exists (select 1 from public.leads l where l.id = lead_id
                 and private.can_see_lead(l.tenant_id, l.business_id, l.owner_id)));
create policy "lead_activities: insert" on public.lead_activities for insert to authenticated
  with check (member_id = private.my_member_id(tenant_id)
              and exists (select 1 from public.leads l where l.id = lead_id
                          and private.can_see_lead(l.tenant_id, l.business_id, l.owner_id)));

grant select, insert, update, delete on public.lead_sources, public.lost_reasons to authenticated;
grant select, insert, update on public.leads to authenticated;
grant select, insert on public.lead_activities to authenticated;
revoke all on public.leads, public.lead_activities, public.lead_sources, public.lost_reasons from anon;

-- ============================================================
-- Helpers for the Leads page (applied as leads_helpers)
-- ============================================================
create or replace function public.member_directory(p_tenant uuid)
returns table (id uuid, name text, role_level int)
language sql stable security definer set search_path = '' as $$
  select m.id, coalesce(nullif(p.full_name, ''), split_part(p.email, '@', 1), 'Team member'), r.level
  from public.tenant_members m
  join public.roles r on r.id = m.role_id
  left join public.profiles p on p.id = m.user_id
  where m.tenant_id = p_tenant and m.status = 'active' and not m.is_support
    and (private.is_member(p_tenant) or private.is_platform_owner())
  order by 2
$$;
revoke execute on function public.member_directory(uuid) from public, anon;
grant execute on function public.member_directory(uuid) to authenticated;

create or replace function public.lead_phone_exists(p_business uuid, p_phone text, p_except uuid default null)
returns boolean
language sql stable security definer set search_path = '' as $$
  select private.can_access_business(p_business) and exists (
    select 1 from public.leads l
    where l.business_id = p_business and not l.is_archived
      and (p_except is null or l.id <> p_except)
      and right(regexp_replace(l.phone, '\D', '', 'g'), 10) = right(regexp_replace(p_phone, '\D', '', 'g'), 10)
  )
$$;
revoke execute on function public.lead_phone_exists(uuid, text, uuid) from public, anon;
grant execute on function public.lead_phone_exists(uuid, text, uuid) to authenticated;

-- Demo data (Viral): 9 leads across the three demo funnels, inserted with execute_sql.
