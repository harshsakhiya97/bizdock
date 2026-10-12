-- Applied via Supabase tool. Existing Business Manager / Caller roles were given funnels access with single updates.
-- ============================================================
-- Funnels: each business has funnels (Lead Gen, Webinar, VSL, Custom),
-- each funnel has its own ordered stages. Leads will sit in a funnel stage.
-- Deleting a funnel in the app = archiving (is_active = false); data is kept.
-- Permission module: 'funnels' (view / add / edit / delete).
-- ============================================================

create table public.funnels (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenants (id) on delete cascade,
  business_id  uuid not null,
  name         text not null,
  type         text not null default 'custom' check (type in ('lead_gen', 'webinar', 'vsl', 'custom')),
  description  text,
  is_active    boolean not null default true,
  archived_at  timestamptz,
  sort_order   int not null default 0,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (id, tenant_id),
  unique (id, business_id),
  foreign key (business_id, tenant_id) references public.businesses (id, tenant_id) on delete cascade
);
create index funnels_business_idx on public.funnels (business_id, tenant_id);
create index funnels_tenant_idx on public.funnels (tenant_id);
create trigger funnels_set_updated_at before update on public.funnels
  for each row execute function public.set_updated_at();

-- kind: open = still in progress, won = converted, lost = closed without sale
create table public.funnel_stages (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null,
  funnel_id      uuid not null,
  name           text not null,
  color          text not null default '#64748b',
  kind           text not null default 'open' check (kind in ('open', 'won', 'lost')),
  note_required  boolean not null default false,   -- a note is asked when a lead enters this stage
  sort_order     int not null default 0,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  foreign key (funnel_id, tenant_id) references public.funnels (id, tenant_id) on delete cascade
);
create index funnel_stages_funnel_idx on public.funnel_stages (funnel_id, sort_order);
create trigger funnel_stages_set_updated_at before update on public.funnel_stages
  for each row execute function public.set_updated_at();

-- ---------- row security ----------
alter table public.funnels enable row level security;
create policy "funnels: read" on public.funnels for select to authenticated
  using (private.can_access_business(business_id) or private.has_permission(tenant_id, 'funnels', 'view'));
create policy "funnels: insert" on public.funnels for insert to authenticated
  with check (private.has_permission(tenant_id, 'funnels', 'add'));
create policy "funnels: update" on public.funnels for update to authenticated
  using (private.has_permission(tenant_id, 'funnels', 'edit') or private.has_permission(tenant_id, 'funnels', 'delete'))
  with check (private.has_permission(tenant_id, 'funnels', 'edit') or private.has_permission(tenant_id, 'funnels', 'delete'));

alter table public.funnel_stages enable row level security;
create policy "funnel_stages: read" on public.funnel_stages for select to authenticated
  using (exists (select 1 from public.funnels f where f.id = funnel_id
                 and (private.can_access_business(f.business_id) or private.has_permission(f.tenant_id, 'funnels', 'view'))));
create policy "funnel_stages: insert" on public.funnel_stages for insert to authenticated
  with check (private.has_permission(tenant_id, 'funnels', 'add') or private.has_permission(tenant_id, 'funnels', 'edit'));
create policy "funnel_stages: update" on public.funnel_stages for update to authenticated
  using (private.has_permission(tenant_id, 'funnels', 'edit'))
  with check (private.has_permission(tenant_id, 'funnels', 'edit'));
create policy "funnel_stages: delete" on public.funnel_stages for delete to authenticated
  using (private.has_permission(tenant_id, 'funnels', 'edit'));

grant select, insert, update on public.funnels to authenticated;
grant select, insert, update, delete on public.funnel_stages to authenticated;

-- ---------- presets: who sees / manages funnels by default ----------
create or replace function private.preset(kind text)
returns jsonb language sql immutable set search_path = '' as $$
  select case kind
    when 'owner' then '{
      "scope": {"leads":"all","customers":"all","sales":"all","dashboards":"all","calendars":"all","attendance":"all"},
      "leads": {"add":true,"edit":true,"delete":true,"assign":true,"export":true},
      "follow_ups": {"add":true},
      "deals": {"add":true,"edit":true},
      "payments": {"view":true,"add":true,"verify":true},
      "collections": {"view":true},
      "finance": {"view":true},
      "customers": {"edit":true},
      "tasks": {"view":true},
      "calendar": {"add":true},
      "team": {"view":true,"add":true,"edit":true},
      "businesses": {"view":true,"add":true,"edit":true,"delete":true},
      "funnels": {"view":true,"add":true,"edit":true,"delete":true},
      "masters": {"edit":true},
      "settings": {"edit":true},
      "activity": {"view":true},
      "access": {"edit":true}
    }'::jsonb
    when 'manager' then '{
      "scope": {"leads":"team","customers":"team","sales":"team","dashboards":"team","calendars":"team","attendance":"team"},
      "leads": {"add":true,"edit":true,"assign":true,"export":true},
      "follow_ups": {"add":true},
      "deals": {"add":true,"edit":true},
      "payments": {"view":true,"add":true},
      "collections": {"view":true},
      "customers": {"edit":true},
      "tasks": {"view":true},
      "calendar": {"add":true},
      "team": {"view":true,"add":true,"edit":true},
      "businesses": {"view":true},
      "funnels": {"view":true,"add":true,"edit":true}
    }'::jsonb
    when 'caller' then '{
      "scope": {"leads":"own","customers":"own","sales":"own","dashboards":"own","calendars":"own","attendance":"own"},
      "leads": {"add":true,"edit":true},
      "follow_ups": {"add":true},
      "deals": {"add":true},
      "payments": {"view":true,"add":true},
      "collections": {"view":true},
      "tasks": {"view":true},
      "funnels": {"view":true}
    }'::jsonb
    when 'accounts' then '{
      "scope": {"leads":"none","customers":"all","sales":"all","dashboards":"own","calendars":"own","attendance":"own"},
      "deals": {"edit":true},
      "payments": {"view":true,"add":true,"verify":true},
      "collections": {"view":true},
      "finance": {"view":true},
      "customers": {"edit":true},
      "tasks": {"view":true}
    }'::jsonb
    else '{}'::jsonb
  end
$$;
