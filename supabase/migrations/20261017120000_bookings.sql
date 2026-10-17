-- ============================================================
-- Enquiry → booking flow (built for the Studio / podcast business, works for any business that rents slots):
--   * leads: purpose, required_on (date) + required_hours — the quick "Add lead" asks only
--     name, phone, source, purpose and required on
--   * message_templates: ready WhatsApp messages by situation (call not received / booking / follow-up / other)
--   * lead_messages: WhatsApp messages sent from a lead (click-to-chat now, provider later)
--   * bookings: a time slot on a date for a lead / client, amount + GST, advance, status;
--     confirmed bookings of a business can't overlap; the first confirmed booking makes the lead a client
--     (customer) and moves it to its funnel's Won stage
--   * booking_payments: advance and later payments → paid / balance
--   * booking invoices: numbered per billing company and financial year (PREFIX/26-27/0001)
-- Visibility: bookings follow the "Sales, payments & collections" visibility; actions: bookings.view / add / edit.
-- ============================================================

alter table public.leads
  add column purpose        text,
  add column required_on    date,
  add column required_hours numeric(5, 2);

-- ---------- WhatsApp templates ----------
create table public.message_templates (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenants (id) on delete cascade,
  business_id uuid references public.businesses (id) on delete cascade,     -- null = every business
  channel     text not null default 'whatsapp' check (channel in ('whatsapp', 'email', 'sms')),
  category    text not null default 'follow_up' check (category in ('call_not_received', 'booking', 'follow_up', 'other')),
  title       text not null,
  body        text not null,
  is_active   boolean not null default true,
  sort_order  int not null default 0,
  created_at  timestamptz not null default now()
);
create index message_templates_tenant_idx on public.message_templates (tenant_id, channel, category);

create table public.lead_messages (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenants (id) on delete cascade,
  lead_id      uuid not null references public.leads (id) on delete cascade,
  channel      text not null default 'whatsapp',
  template_id  uuid references public.message_templates (id) on delete set null,
  title        text,
  body         text not null,
  via          text not null default 'click_to_chat',   -- later: provider
  sent_by      uuid references public.tenant_members (id) on delete set null,
  sent_at      timestamptz not null default now()
);
create index lead_messages_lead_idx on public.lead_messages (lead_id, sent_at desc);

-- ---------- bookings ----------
create table public.bookings (
  id                  uuid primary key default gen_random_uuid(),
  tenant_id           uuid not null references public.tenants (id) on delete cascade,
  business_id         uuid not null,
  lead_id             uuid references public.leads (id) on delete set null,
  customer_id         uuid references public.customers (id) on delete set null,
  client_name         text not null,
  phone               text,
  purpose             text,
  booking_date        date not null,
  start_time          time not null,
  end_time            time not null,
  amount              numeric(12, 2) not null default 0,       -- before GST
  gst_applicable      boolean not null default false,
  gst_rate            numeric(5, 2) not null default 18,
  gst_amount          numeric(12, 2) not null default 0,
  total_amount        numeric(12, 2) not null default 0,
  paid_amount         numeric(12, 2) not null default 0,       -- kept from booking_payments
  status              text not null default 'confirmed' check (status in ('tentative', 'confirmed', 'completed', 'cancelled')),
  billing_company_id  uuid references public.billing_companies (id) on delete set null,
  invoice_no          text,
  invoice_date        date,
  notes               text,
  owner_id            uuid references public.tenant_members (id) on delete set null,
  created_by          uuid references public.tenant_members (id) on delete set null,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  check (end_time > start_time),
  foreign key (business_id, tenant_id) references public.businesses (id, tenant_id) on delete cascade
);
create index bookings_business_date_idx on public.bookings (business_id, booking_date);
create index bookings_lead_idx on public.bookings (lead_id);
create index bookings_customer_idx on public.bookings (customer_id);
create unique index bookings_invoice_no_key on public.bookings (tenant_id, invoice_no) where invoice_no is not null;
create trigger bookings_set_updated_at before update on public.bookings
  for each row execute function public.set_updated_at();

create table public.booking_payments (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references public.tenants (id) on delete cascade,
  booking_id       uuid not null references public.bookings (id) on delete cascade,
  amount           numeric(12, 2) not null check (amount > 0),
  paid_on          date not null default current_date,
  payment_mode_id  uuid references public.payment_modes (id) on delete set null,
  reference        text,
  note             text,
  received_by      uuid references public.tenant_members (id) on delete set null,
  created_at       timestamptz not null default now()
);
create index booking_payments_booking_idx on public.booking_payments (booking_id);

create table public.invoice_counters (
  billing_company_id uuid not null references public.billing_companies (id) on delete cascade,
  fy                 text not null,           -- e.g. 26-27
  last_no            int not null default 0,
  primary key (billing_company_id, fy)
);

-- amounts, overlap check
create or replace function private.booking_before_save()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  new.gst_amount := case when new.gst_applicable then round(new.amount * new.gst_rate / 100, 2) else 0 end;
  new.total_amount := new.amount + new.gst_amount;
  if new.status = 'confirmed' and exists (
    select 1 from public.bookings b
    where b.business_id = new.business_id and b.booking_date = new.booking_date and b.status = 'confirmed'
      and b.id <> new.id and b.start_time < new.end_time and b.end_time > new.start_time
  ) then
    raise exception 'This slot overlaps another confirmed booking on %.', to_char(new.booking_date, 'DD Mon YYYY');
  end if;
  return new;
end;
$$;
create trigger bookings_before_save before insert or update on public.bookings
  for each row execute function private.booking_before_save();

-- first confirmed booking: the lead becomes a client and moves to its funnel's Won stage
create or replace function private.booking_after_save()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  l    public.leads;
  cid  uuid;
  won  uuid;
begin
  if new.status not in ('confirmed', 'completed') then return new; end if;
  if new.customer_id is null and new.lead_id is not null then
    select * into l from public.leads where id = new.lead_id;
    select id into cid from public.customers where lead_id = new.lead_id and not is_archived limit 1;
    if cid is null then
      insert into public.customers (tenant_id, business_id, lead_id, full_name, phone, email, city, stage_id, owner_id, created_by)
      values (new.tenant_id, new.business_id, new.lead_id, trim(concat_ws(' ', l.first_name, l.last_name)), l.phone, l.email, l.city,
              (select id from public.customer_stages where tenant_id = new.tenant_id and is_active order by sort_order limit 1),
              coalesce(l.owner_id, new.owner_id), new.created_by)
      returning id into cid;
    end if;
    update public.bookings set customer_id = cid where id = new.id;
  end if;
  if new.lead_id is not null then
    select * into l from public.leads where id = new.lead_id;
    if l.funnel_id is not null then
      select id into won from public.funnel_stages where funnel_id = l.funnel_id and kind = 'won' order by sort_order limit 1;
      if won is not null and l.stage_id is distinct from won then
        update public.leads set stage_id = won where id = l.id;
        insert into public.lead_activities (tenant_id, lead_id, kind, from_stage_id, to_stage_id, note, member_id)
        values (l.tenant_id, l.id, 'stage', l.stage_id, won, 'Booked ' || to_char(new.booking_date, 'DD Mon') , new.created_by);
      end if;
    end if;
  end if;
  return new;
end;
$$;
create trigger bookings_after_save after insert or update of status, lead_id on public.bookings
  for each row execute function private.booking_after_save();

-- paid_amount = sum of payments
create or replace function private.sync_booking_paid()
returns trigger language plpgsql security definer set search_path = '' as $$
declare b uuid := coalesce(new.booking_id, old.booking_id);
begin
  update public.bookings set paid_amount = coalesce((select sum(amount) from public.booking_payments where booking_id = b), 0) where id = b;
  return null;
end;
$$;
create trigger booking_payments_sync after insert or update or delete on public.booking_payments
  for each row execute function private.sync_booking_paid();

create or replace function private.can_see_booking(bk uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.bookings b where b.id = bk and private.can_see_owned(b.tenant_id, b.business_id, b.owner_id, 'sales'))
$$;

-- invoice number for a booking: PREFIX/FY/0001 per billing company (kept once given)
create or replace function public.booking_invoice(p_booking uuid, p_company uuid)
returns text language plpgsql security definer set search_path = '' as $$
declare
  b    public.bookings;
  c    public.billing_companies;
  v_fy text;
  n    int;
  v_no text;
begin
  select * into b from public.bookings where id = p_booking;
  if b.id is null or not private.can_see_booking(b.id) then raise exception 'Booking not found.'; end if;
  if not private.has_permission(b.tenant_id, 'bookings', 'edit') then raise exception 'You don’t have permission to create invoices.'; end if;
  if b.invoice_no is not null then return b.invoice_no; end if;
  if b.status = 'cancelled' then raise exception 'A cancelled booking has no invoice.'; end if;
  select * into c from public.billing_companies where id = coalesce(p_company, b.billing_company_id) and tenant_id = b.tenant_id;
  if c.id is null then raise exception 'Pick the billing company.'; end if;
  v_fy := case when extract(month from current_date) >= 4
               then to_char(current_date, 'YY') || '-' || to_char(current_date + interval '1 year', 'YY')
               else to_char(current_date - interval '1 year', 'YY') || '-' || to_char(current_date, 'YY') end;
  insert into public.invoice_counters as ic (billing_company_id, fy, last_no) values (c.id, v_fy, 1)
  on conflict (billing_company_id, fy) do update set last_no = ic.last_no + 1
  returning ic.last_no into n;
  v_no := coalesce(nullif(c.invoice_prefix, ''), 'INV') || '/' || v_fy || '/' || lpad(n::text, 4, '0');
  update public.bookings set invoice_no = v_no, invoice_date = current_date, billing_company_id = c.id where id = b.id;
  return v_no;
end;
$$;

-- ---------- row security ----------
alter table public.message_templates enable row level security;
create policy "message_templates: read" on public.message_templates for select to authenticated
  using (private.is_member(tenant_id) or private.is_platform_owner());
create policy "message_templates: write" on public.message_templates for all to authenticated
  using (private.has_permission(tenant_id, 'masters', 'edit'))
  with check (private.has_permission(tenant_id, 'masters', 'edit'));

alter table public.lead_messages enable row level security;
create policy "lead_messages: read" on public.lead_messages for select to authenticated
  using (exists (select 1 from public.leads l where l.id = lead_id and private.can_see_lead(l.tenant_id, l.business_id, l.owner_id)));
create policy "lead_messages: insert" on public.lead_messages for insert to authenticated
  with check (sent_by = private.my_member_id(tenant_id)
              and exists (select 1 from public.leads l where l.id = lead_id and private.can_see_lead(l.tenant_id, l.business_id, l.owner_id)));

alter table public.bookings enable row level security;
create policy "bookings: read" on public.bookings for select to authenticated
  using (private.can_see_owned(tenant_id, business_id, owner_id, 'sales'));
create policy "bookings: insert" on public.bookings for insert to authenticated
  with check (private.has_permission(tenant_id, 'bookings', 'add') and private.can_access_business(business_id));
create policy "bookings: update" on public.bookings for update to authenticated
  using (private.has_permission(tenant_id, 'bookings', 'edit') and private.can_see_owned(tenant_id, business_id, owner_id, 'sales'))
  with check (private.can_access_business(business_id));

alter table public.booking_payments enable row level security;
create policy "booking_payments: read" on public.booking_payments for select to authenticated
  using (private.can_see_booking(booking_id));
create policy "booking_payments: insert" on public.booking_payments for insert to authenticated
  with check ((private.has_permission(tenant_id, 'bookings', 'add') or private.has_permission(tenant_id, 'payments', 'add'))
              and private.can_see_booking(booking_id));
create policy "booking_payments: delete" on public.booking_payments for delete to authenticated
  using (private.has_permission(tenant_id, 'bookings', 'edit') and private.can_see_booking(booking_id));

alter table public.invoice_counters enable row level security;   -- only through booking_invoice()

grant select, insert, update, delete on public.message_templates to authenticated;
grant select, insert on public.lead_messages to authenticated;
grant select, insert, update on public.bookings to authenticated;
grant select, insert, delete on public.booking_payments to authenticated;
revoke all on public.message_templates, public.lead_messages, public.bookings, public.booking_payments, public.invoice_counters from anon;

-- ---------- WhatsApp templates seeded for every workspace (applied as message_templates_seed) ----------
-- private.seed_message_templates(t) inserts 13 templates (call not received ×5, booking ×5, follow-up ×3)
-- when the workspace has none; trigger tenants_seed_templates runs it for new workspaces.
-- Variables: {{first_name}} {{name}} {{purpose}} {{required_on}} {{business}} {{booking_date}} {{booking_time}}
-- Roles (execute_sql): Business Manager bookings view/add/edit, Caller view/add, Accounts view/edit.
