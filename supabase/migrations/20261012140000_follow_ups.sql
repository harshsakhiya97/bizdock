-- ============================================================
-- Follow-ups: scheduled calls / messages / meetings on a lead.
-- status: pending → done (with an outcome) | rescheduled (replaced by a newer one) | cancelled
-- leads.next_follow_up_at is kept equal to the earliest pending follow-up (trigger).
-- Who sees a follow-up follows who sees its lead.
-- ============================================================

create table public.follow_up_outcomes (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenants (id) on delete cascade,
  name        text not null,
  is_active   boolean not null default true,
  sort_order  int not null default 0,
  created_at  timestamptz not null default now(),
  unique (tenant_id, name)
);

create table public.follow_ups (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenants (id) on delete cascade,
  lead_id       uuid not null references public.leads (id) on delete cascade,
  assigned_to   uuid references public.tenant_members (id) on delete set null,
  due_at        timestamptz not null,
  mode          text not null default 'call' check (mode in ('call', 'whatsapp', 'meeting', 'email', 'visit', 'other')),
  purpose       text,
  status        text not null default 'pending' check (status in ('pending', 'done', 'rescheduled', 'cancelled')),
  outcome_id    uuid references public.follow_up_outcomes (id) on delete set null,
  result_note   text,
  completed_at  timestamptz,
  completed_by  uuid references public.tenant_members (id) on delete set null,
  created_by    uuid references public.tenant_members (id) on delete set null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index follow_ups_tenant_due_idx on public.follow_ups (tenant_id, status, due_at);
create index follow_ups_lead_idx on public.follow_ups (lead_id, status);
create index follow_ups_assigned_idx on public.follow_ups (assigned_to, status, due_at);
create trigger follow_ups_set_updated_at before update on public.follow_ups
  for each row execute function public.set_updated_at();

-- keep the lead's "next follow-up" in step with its earliest pending follow-up
create or replace function private.sync_lead_follow_up()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  lid uuid := coalesce(new.lead_id, old.lead_id);
begin
  update public.leads l
  set next_follow_up_at = (select min(f.due_at) from public.follow_ups f where f.lead_id = lid and f.status = 'pending')
  where l.id = lid;
  return null;
end;
$$;
create trigger follow_ups_sync_lead after insert or update or delete on public.follow_ups
  for each row execute function private.sync_lead_follow_up();

-- masters: call outcomes
create or replace function private.seed_follow_up_outcomes(t uuid)
returns void language sql security definer set search_path = '' as $$
  insert into public.follow_up_outcomes (tenant_id, name, sort_order)
  select t, s.name, s.ord from unnest(array[
    'Connected – interested', 'Connected – not interested', 'Call back later', 'Not answered', 'Busy',
    'Switched off', 'Wrong number', 'Meeting fixed', 'Payment promised', 'Details shared on WhatsApp', 'Other'
  ]) with ordinality as s(name, ord)
  on conflict do nothing;
$$;
create or replace function private.seed_new_tenant_outcomes()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform private.seed_follow_up_outcomes(new.id);
  return new;
end;
$$;
create trigger tenants_seed_outcomes after insert on public.tenants
  for each row execute function private.seed_new_tenant_outcomes();
select private.seed_follow_up_outcomes(id) from public.tenants;

-- ---------- row security ----------
alter table public.follow_up_outcomes enable row level security;
create policy "follow_up_outcomes: read" on public.follow_up_outcomes for select to authenticated
  using (private.is_member(tenant_id) or private.is_platform_owner());
create policy "follow_up_outcomes: write" on public.follow_up_outcomes for all to authenticated
  using (private.has_permission(tenant_id, 'masters', 'edit'))
  with check (private.has_permission(tenant_id, 'masters', 'edit'));

alter table public.follow_ups enable row level security;
create policy "follow_ups: read" on public.follow_ups for select to authenticated
  using (exists (select 1 from public.leads l where l.id = lead_id
                 and private.can_see_lead(l.tenant_id, l.business_id, l.owner_id)));
create policy "follow_ups: insert" on public.follow_ups for insert to authenticated
  with check ((private.has_permission(tenant_id, 'follow_ups', 'add') or private.has_permission(tenant_id, 'leads', 'edit'))
              and exists (select 1 from public.leads l where l.id = lead_id and l.tenant_id = follow_ups.tenant_id
                          and private.can_see_lead(l.tenant_id, l.business_id, l.owner_id)));
create policy "follow_ups: update" on public.follow_ups for update to authenticated
  using ((private.has_permission(tenant_id, 'follow_ups', 'add') or private.has_permission(tenant_id, 'leads', 'edit'))
         and exists (select 1 from public.leads l where l.id = lead_id
                     and private.can_see_lead(l.tenant_id, l.business_id, l.owner_id)))
  with check (true);

grant select, insert, update, delete on public.follow_up_outcomes to authenticated;
grant select, insert, update on public.follow_ups to authenticated;
-- (revokes for anon applied separately)
