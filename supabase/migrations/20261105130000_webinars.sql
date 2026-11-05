-- Webinar businesses: webinar hosts and products (Masters), webinars (one-time, several dates or weekly; each date its own
-- calendar event + Zoom webinar, the next one made when the one before ends), registrations (a lead on one date, with its
-- own Zoom join link), polls from Zoom, purchases (paid in parts; the first paid part makes the lead a customer), and the
-- Before / After webinar triggers (per registered lead, per date).

-- ---------- Masters: webinar hosts ----------
create table if not exists public.webinar_hosts (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  name text not null check (length(btrim(name)) between 1 and 120),
  email text,
  phone text,
  is_active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now()
);
create index if not exists webinar_hosts_tenant on public.webinar_hosts (tenant_id);
alter table public.webinar_hosts enable row level security;
create policy "webinar_hosts: read" on public.webinar_hosts for select
  using (private.is_member(tenant_id) or private.is_platform_owner());
-- Masters, or whoever adds webinars ("Add new host" while creating one)
create policy "webinar_hosts: insert" on public.webinar_hosts for insert
  with check (private.has_permission(tenant_id, 'masters', 'edit') or private.has_permission(tenant_id, 'bookings', 'add'));
create policy "webinar_hosts: update" on public.webinar_hosts for update
  using (private.has_permission(tenant_id, 'masters', 'edit'))
  with check (private.has_permission(tenant_id, 'masters', 'edit'));
create policy "webinar_hosts: delete" on public.webinar_hosts for delete
  using (private.has_permission(tenant_id, 'masters', 'edit'));

-- ---------- Masters: products (same table as services, told apart by kind) ----------
alter table public.products add column if not exists kind text not null default 'service';
do $$ begin
  alter table public.products add constraint products_kind_check check (kind in ('service', 'product'));
exception when duplicate_object then null; end $$;

-- ---------- webinars ----------
create table if not exists public.webinars (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  business_id uuid not null references public.businesses(id) on delete cascade,
  title text not null check (length(btrim(title)) between 1 and 200),
  description text,
  host_id uuid references public.webinar_hosts(id) on delete set null,
  zoom_account_id uuid references public.integrations(id) on delete set null,
  funnel_id uuid references public.funnels(id) on delete set null,
  -- once: first_date · dates: the listed dates · weekly: these weekdays (0 Sunday … 6 Saturday) from first_date
  repeat text not null default 'once' check (repeat in ('once', 'dates', 'weekly')),
  first_date date not null,
  dates date[] not null default '{}',
  weekdays smallint[] not null default '{}',
  -- weekly: the last day it may run (null = never stops)
  stop_date date,
  start_time time not null,
  end_time time not null,
  is_active boolean not null default true,
  archived_at timestamptz,
  created_by uuid references public.tenant_members(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (end_time > start_time)
);
create index if not exists webinars_tenant on public.webinars (tenant_id);
create index if not exists webinars_funnel on public.webinars (funnel_id);
alter table public.webinars enable row level security;
create policy "webinars: read" on public.webinars for select
  using ((private.is_member(tenant_id) or private.is_platform_owner()) and private.can_access_business(business_id));
create policy "webinars: insert" on public.webinars for insert
  with check (private.has_permission(tenant_id, 'bookings', 'add') and private.can_access_business(business_id));
create policy "webinars: update" on public.webinars for update
  using ((private.has_permission(tenant_id, 'bookings', 'edit') or private.has_permission(tenant_id, 'bookings', 'add')) and private.can_access_business(business_id))
  with check (private.can_access_business(business_id));
create trigger webinars_set_updated_at before update on public.webinars for each row execute function set_updated_at();

alter table public.events add column if not exists webinar_id uuid references public.webinars(id) on delete set null;
create index if not exists events_webinar on public.events (webinar_id, event_date);
alter table public.workflows add column if not exists webinar_id uuid references public.webinars(id) on delete set null;
alter table public.workflow_runs add column if not exists event_id uuid references public.events(id) on delete set null;
-- a Before / After webinar workflow runs once per lead per date
create unique index if not exists workflow_runs_event_once on public.workflow_runs (workflow_id, lead_id, event_id)
  where event_id is not null and not is_test;

-- ---------- registrations: a lead on one date of a webinar ----------
create table if not exists public.webinar_registrations (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  webinar_id uuid not null references public.webinars(id) on delete cascade,
  event_id uuid not null references public.events(id) on delete cascade,
  lead_id uuid not null references public.leads(id) on delete cascade,
  registrant_id text,
  join_url text,
  short_link text,
  -- after the webinar (Get webinar analytics): Super Hot / Hot / Warm / Cold
  category text check (category in ('super_hot', 'hot', 'warm', 'cold')),
  attended_minutes integer,
  categorized_at timestamptz,
  created_at timestamptz not null default now(),
  unique (event_id, lead_id)
);
create index if not exists webinar_registrations_lead on public.webinar_registrations (lead_id);
alter table public.webinar_registrations enable row level security;
create policy "webinar_registrations: read" on public.webinar_registrations for select using (private.can_see_event(event_id));

-- ---------- polls from Zoom ----------
alter table public.zoom_comments drop constraint if exists zoom_comments_kind_check;
alter table public.zoom_comments add constraint zoom_comments_kind_check check (kind in ('qa', 'chat', 'poll'));

-- ---------- purchases (Products bought by a lead, paid in parts) ----------
create table if not exists public.purchases (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  business_id uuid not null references public.businesses(id) on delete cascade,
  lead_id uuid not null references public.leads(id) on delete cascade,
  product_id uuid references public.products(id) on delete set null,
  name text not null check (length(btrim(name)) between 1 and 200),
  price numeric not null default 0 check (price >= 0),
  gst_applicable boolean not null default false,
  gst_rate numeric not null default 18,
  gst_amount numeric not null default 0,
  total_amount numeric not null default 0 check (total_amount >= 0),
  -- the paid parts added up (kept by a trigger)
  paid_amount numeric not null default 0,
  purchase_date date not null default current_date,
  notes text,
  status text not null default 'active' check (status in ('active', 'cancelled')),
  created_by uuid references public.tenant_members(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists purchases_lead on public.purchases (lead_id);
create index if not exists purchases_tenant on public.purchases (tenant_id);
alter table public.purchases enable row level security;
create policy "purchases: read" on public.purchases for select
  using ((private.is_member(tenant_id) or private.is_platform_owner()) and private.can_access_business(business_id));
create policy "purchases: insert" on public.purchases for insert
  with check (private.has_permission(tenant_id, 'leads', 'edit') and private.can_access_business(business_id));
create policy "purchases: update" on public.purchases for update
  using (private.has_permission(tenant_id, 'leads', 'edit') and private.can_access_business(business_id))
  with check (private.can_access_business(business_id));
create policy "purchases: delete" on public.purchases for delete
  using (private.has_permission(tenant_id, 'leads', 'edit') and private.can_access_business(business_id));
create trigger purchases_set_updated_at before update on public.purchases for each row execute function set_updated_at();

create table if not exists public.purchase_payments (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  purchase_id uuid not null references public.purchases(id) on delete cascade,
  label text,
  amount numeric not null check (amount > 0),
  due_on date,
  paid_on date,
  status text not null default 'pending' check (status in ('pending', 'paid')),
  payment_mode_id uuid references public.payment_modes(id) on delete set null,
  note text,
  received_by uuid references public.tenant_members(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists purchase_payments_purchase on public.purchase_payments (purchase_id);
alter table public.purchase_payments enable row level security;
create policy "purchase_payments: read" on public.purchase_payments for select
  using (exists (select 1 from public.purchases p where p.id = purchase_id));
create policy "purchase_payments: write" on public.purchase_payments for all
  using (private.has_permission(tenant_id, 'leads', 'edit') and exists (select 1 from public.purchases p where p.id = purchase_id))
  with check (private.has_permission(tenant_id, 'leads', 'edit') and exists (select 1 from public.purchases p where p.id = purchase_id));

create or replace function private.purchase_paid_sum() returns trigger
language plpgsql security definer set search_path = '' as $$
declare pid uuid := coalesce(new.purchase_id, old.purchase_id);
begin
  update public.purchases set paid_amount = coalesce((select sum(amount) from public.purchase_payments where purchase_id = pid and status = 'paid'), 0)
   where id = pid;
  return null;
end $$;
create trigger purchase_payments_sum after insert or update or delete on public.purchase_payments
  for each row execute function private.purchase_paid_sum();

-- ---------- the dates of a webinar ----------
-- the first date of the webinar after p_after (null: from its first date) whose start is still ahead (India time)
create or replace function private.webinar_next_date(w public.webinars, p_after date) returns date
language plpgsql stable set search_path = '' as $$
declare
  d date;
  today date := (now() at time zone 'Asia/Kolkata')::date;
begin
  if w.repeat = 'once' then
    if p_after is not null and w.first_date <= p_after then return null; end if;
    if ((w.first_date + w.start_time) at time zone 'Asia/Kolkata') <= now() then return null; end if;
    return w.first_date;
  elsif w.repeat = 'dates' then
    select min(x) into d from unnest(w.dates) x
     where (p_after is null or x > p_after) and ((x + w.start_time) at time zone 'Asia/Kolkata') > now();
    return d;
  end if;
  -- weekly
  if coalesce(array_length(w.weekdays, 1), 0) = 0 then return null; end if;
  d := greatest(w.first_date, coalesce(p_after + 1, w.first_date), today);
  for i in 0..14 loop
    if w.stop_date is not null and d > w.stop_date then return null; end if;
    if extract(dow from d)::int = any (w.weekdays) and ((d + w.start_time) at time zone 'Asia/Kolkata') > now() then return d; end if;
    d := d + 1;
  end loop;
  return null;
end $$;

-- the webinar's next date as a calendar event (with its Zoom webinar): kept in line with the webinar while it hasn't
-- started; a new one only when none is coming up and the one before has ended (p_force: also while one is on, for
-- someone registering during it). Returns the coming date's event, or null.
create or replace function private.webinar_ensure_next(p_webinar uuid, p_force boolean default false) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  w public.webinars;
  up public.events;
  last_d date;
  live boolean;
  nd date;
  tid uuid;
  eid uuid;
begin
  select * into w from public.webinars where id = p_webinar;
  if w.id is null or w.archived_at is not null then return null; end if;
  select * into up from public.events e
   where e.webinar_id = w.id and not e.is_cancelled and ((e.event_date + e.start_time) at time zone 'Asia/Kolkata') > now()
   order by e.event_date, e.start_time limit 1;
  select max(e.event_date) into last_d from public.events e
   where e.webinar_id = w.id and not e.is_cancelled and ((e.event_date + e.start_time) at time zone 'Asia/Kolkata') <= now();
  live := exists (select 1 from public.events e
   where e.webinar_id = w.id and not e.is_cancelled
     and ((e.event_date + e.start_time) at time zone 'Asia/Kolkata') <= now()
     and ((e.event_date + coalesce(e.end_time, e.start_time)) at time zone 'Asia/Kolkata') > now());
  nd := private.webinar_next_date(w, last_d);

  if up.id is not null then
    if nd is null then
      -- the webinar no longer has this date (e.g. the stop date moved): call it off
      update public.events set is_cancelled = true where id = up.id;
      return null;
    end if;
    update public.events
       set event_date = nd, start_time = w.start_time, end_time = w.end_time, title = w.title, description = w.description,
           zoom_account_id = w.zoom_account_id, zoom_kind = 'webinar', business_id = w.business_id
     where id = up.id
       and (event_date, start_time, end_time, title, coalesce(description, ''), zoom_account_id, business_id)
           is distinct from (nd, w.start_time, w.end_time, w.title, coalesce(w.description, ''), w.zoom_account_id, w.business_id);
    return up.id;
  end if;
  if not w.is_active or nd is null then return null; end if;
  if live and not p_force then return null; end if;

  select id into tid from public.event_types where tenant_id = w.tenant_id and kind = 'webinar' order by is_active desc, sort_order limit 1;
  if tid is null then
    insert into public.event_types (tenant_id, name, kind, color, sort_order) values (w.tenant_id, 'Webinar', 'webinar', '#8b5cf6', 1)
    returning id into tid;
  end if;
  insert into public.events (tenant_id, business_id, type_id, title, event_date, start_time, end_time, description,
                             zoom_account_id, zoom_kind, webinar_id, series_id, created_by)
  values (w.tenant_id, w.business_id, tid, w.title, nd, w.start_time, w.end_time, w.description,
          w.zoom_account_id, 'webinar', w.id, w.id, w.created_by)
  returning id into eid;
  return eid;
end $$;

-- for the workflow runner (Register for webinar): the date to register on
create or replace function public.webinar_upcoming(p_webinar uuid) returns uuid
language sql security definer set search_path = '' as $$
  select private.webinar_ensure_next(p_webinar, true)
$$;
revoke all on function public.webinar_upcoming(uuid) from public, anon, authenticated;
grant execute on function public.webinar_upcoming(uuid) to service_role;

-- a saved webinar: its next date follows; a deleted one calls off its coming dates
create or replace function private.webinar_changed() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.archived_at is not null then
    if tg_op = 'UPDATE' and old.archived_at is null then
      update public.events set is_cancelled = true
       where webinar_id = new.id and not is_cancelled and ((event_date + start_time) at time zone 'Asia/Kolkata') > now();
    end if;
    return new;
  end if;
  perform private.webinar_ensure_next(new.id);
  return new;
end $$;
create trigger webinars_changed after insert or update on public.webinars
  for each row execute function private.webinar_changed();

-- every minute: each webinar's next date once the one before has ended
create or replace function private.webinar_roll() returns void
language plpgsql security definer set search_path = '' as $$
declare r record;
begin
  for r in select id from public.webinars where is_active and archived_at is null loop
    begin
      perform private.webinar_ensure_next(r.id);
    exception when others then null;
    end;
  end loop;
end $$;

-- ---------- Before / After webinar triggers ----------
-- each registered lead of each date of the workflow's webinar: some time before the start / after the end
create or replace function private.start_webinar_workflows() returns void
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.workflow_runs (tenant_id, workflow_id, lead_id, event_id)
  select w.tenant_id, w.id, r.lead_id, e.id
    from public.workflows w
    cross join lateral (
      select coalesce(nullif(n.value -> 'data' ->> 'amount', '')::numeric, 0)
             * case n.value -> 'data' ->> 'unit' when 'days' then 1440 when 'hours' then 60 else 1 end as mins
        from jsonb_array_elements(w.nodes) n where n.value ->> 'id' = 'trigger' limit 1) t
    join public.events e on e.webinar_id = w.webinar_id and not e.is_cancelled
    join public.webinar_registrations r on r.event_id = e.id
   where w.is_active and w.archived_at is null and w.webinar_id is not null
     and w.trigger_type in ('before_event', 'after_event')
     and case when w.trigger_type = 'before_event' then
            ((e.event_date + e.start_time) at time zone 'Asia/Kolkata') - make_interval(mins => t.mins::int) <= now()
            and ((e.event_date + e.start_time) at time zone 'Asia/Kolkata') > now()
          else
            ((e.event_date + coalesce(e.end_time, e.start_time)) at time zone 'Asia/Kolkata') + make_interval(mins => t.mins::int) <= now()
            and ((e.event_date + coalesce(e.end_time, e.start_time)) at time zone 'Asia/Kolkata') + make_interval(mins => t.mins::int) > now() - interval '1 day'
          end
  on conflict (workflow_id, lead_id, event_id) where event_id is not null and not is_test do nothing;
end $$;

select cron.unschedule('workflow-runner');
select cron.schedule('workflow-runner', '10 seconds', $job$
  select private.start_webinar_workflows();
  update public.workflow_runs set status = 'queued' where status = 'running' and updated_at < now() - interval '10 minutes';
  select private.kick_workflow_runner()
  where exists (select 1 from public.workflow_runs where status in ('queued', 'waiting') and next_at <= now());
$job$);
select cron.schedule('webinar-roll', '* * * * *', $job$ select private.webinar_roll(); $job$);
