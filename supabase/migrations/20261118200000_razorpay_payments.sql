-- Razorpay (System Connections: Key ID + Key Secret). The razorpay edge function pulls the account's payments every
-- 5 minutes (and on Sync) into razorpay_payments; Side menu → Payments → History logs lists them. A payment is matched
-- to a lead by phone (last 10 digits), else email. Role access → Payments → view.

create table if not exists public.razorpay_payments (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  integration_id uuid references public.integrations(id) on delete set null,
  payment_id text not null,
  order_id text,
  invoice_id text,
  amount numeric not null default 0,          -- ₹ (Razorpay sends paise)
  currency text,
  status text,                                -- created / authorized / captured / refunded / failed
  method text,                                -- upi / card / netbanking / wallet / emi …
  captured boolean,
  email text,
  phone text,
  description text,
  notes jsonb not null default '{}'::jsonb,
  amount_refunded numeric not null default 0,
  refund_status text,
  fee numeric,
  tax numeric,
  error_description text,
  vpa text,
  bank text,
  wallet text,
  paid_at timestamptz not null,               -- the payment's time at Razorpay
  lead_id uuid references public.leads(id) on delete set null,
  raw jsonb,
  synced_at timestamptz not null default now(),
  unique (tenant_id, payment_id)
);
create index if not exists razorpay_payments_tenant_time on public.razorpay_payments (tenant_id, paid_at desc);
create index if not exists razorpay_payments_lead on public.razorpay_payments (lead_id);

alter table public.razorpay_payments enable row level security;
drop policy if exists "razorpay_payments: read" on public.razorpay_payments;
create policy "razorpay_payments: read" on public.razorpay_payments for select
  using (private.has_permission(tenant_id, 'payments', 'view'));
grant select on public.razorpay_payments to authenticated;

-- the lead with that phone (last 10 digits), else that email
create or replace function private.razorpay_match_lead() returns trigger language plpgsql security definer set search_path to '' as $$
declare ph text := right(regexp_replace(coalesce(new.phone, ''), '\D', '', 'g'), 10);
begin
  if new.lead_id is not null then return new; end if;
  if length(ph) = 10 then
    select l.id into new.lead_id from public.leads l
     where l.tenant_id = new.tenant_id and not coalesce(l.is_archived, false)
       and right(regexp_replace(coalesce(l.phone, ''), '\D', '', 'g'), 10) = ph
     order by l.created_at desc limit 1;
  end if;
  if new.lead_id is null and nullif(trim(new.email), '') is not null then
    select l.id into new.lead_id from public.leads l
     where l.tenant_id = new.tenant_id and not coalesce(l.is_archived, false) and lower(l.email) = lower(trim(new.email))
     order by l.created_at desc limit 1;
  end if;
  return new;
end $$;
drop trigger if exists razorpay_payments_match on public.razorpay_payments;
create trigger razorpay_payments_match before insert or update on public.razorpay_payments
  for each row execute function private.razorpay_match_lead();

-- Sync from the Payments page: who may press it
create or replace function public.can_see_payments(p_tenant uuid) returns boolean language sql stable security definer set search_path to '' as $$
  select private.has_permission(p_tenant, 'payments', 'view')
$$;
revoke all on function public.can_see_payments(uuid) from public, anon;
grant execute on function public.can_see_payments(uuid) to authenticated;

-- every 5 minutes while a Razorpay account is connected
create or replace function private.kick_razorpay() returns void language sql security definer set search_path to '' as $$
  select net.http_post(
    url := 'https://tnnjudehqalkgglzkfik.supabase.co/functions/v1/razorpay',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-secret', public.workflow_cron_secret()),
    body := '{"action":"cron"}'::jsonb,
    timeout_milliseconds := 55000
  );
$$;
do $$
begin
  perform cron.unschedule('razorpay-sync') where exists (select 1 from cron.job where jobname = 'razorpay-sync');
  perform cron.schedule('razorpay-sync', '*/5 * * * *', $c$
    select private.kick_razorpay()
     where exists (select 1 from public.integrations where provider = 'razorpay' and is_enabled);
  $c$);
end $$;
