-- WhatsApp module (side menu → WhatsApp: Individual chat, Campaign, History logs, Templates)
--
-- Access (Role access → WhatsApp):
--   scope "whatsapp" (All / Team / Own / None): whose chats and history logs they see
--     Own  = messages they sent, or to / from a lead they own; Team = the same for their team
--   whatsapp.campaign  : send campaigns (and see the campaign reports)
--   whatsapp.templates : add / delete templates
--
-- Campaigns: one approved template to many numbers (leads, customers, team, a CSV or pasted numbers),
-- now or at a time. The wa-campaign edge function sends them about 1 a second; each message is kept in
-- whatsapp_logs (source 'campaign') so delivered / read / replies come from the WATI webhook as usual.

-- 1 · who sees a log line
create or replace function private.can_see_wa(t uuid, p_phone text, p_sent_by uuid)
returns boolean language sql stable security definer set search_path to '' as $$
  select case private.area_scope(t, 'whatsapp')
    when 'all' then true
    when 'team' then p_sent_by in (select private.my_team(t))
      or exists (select 1 from public.leads l where l.tenant_id = t and private.ph10(l.phone) = private.ph10(p_phone)
                   and l.owner_id in (select private.my_team(t)))
    when 'own' then p_sent_by = private.my_member_id(t)
      or exists (select 1 from public.leads l where l.tenant_id = t and private.ph10(l.phone) = private.ph10(p_phone)
                   and l.owner_id = private.my_member_id(t))
    else false
  end
$$;

create policy "whatsapp_logs: whatsapp read" on public.whatsapp_logs
  for select to authenticated using (private.can_see_wa(tenant_id, phone, sent_by));

-- what the whatsapp-templates function lets the caller do: list (any member) / send / manage
create or replace function public.wa_can(p_tenant uuid, p_what text)
returns boolean language sql stable security definer set search_path to '' as $$
  select case p_what
    when 'list' then private.my_member_id(p_tenant) is not null or private.is_platform_owner()
    when 'send' then private.has_permission(p_tenant, 'settings', 'edit') or private.has_permission(p_tenant, 'whatsapp', 'campaign')
                     or coalesce(private.area_scope(p_tenant, 'whatsapp'), 'none') <> 'none'
    when 'manage' then private.has_permission(p_tenant, 'settings', 'edit') or private.has_permission(p_tenant, 'whatsapp', 'templates')
    else false
  end
$$;
revoke all on function public.wa_can(uuid, text) from public, anon;
grant execute on function public.wa_can(uuid, text) to authenticated;

-- 2 · campaigns
create table public.wa_campaigns (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  name text not null,
  template text not null,
  template_language text,
  template_body text,
  /** { kind: leads | customers | team | csv | paste, label, filters } — shown in the list */
  audience jsonb not null default '{}'::jsonb,
  total int not null default 0,
  status text not null default 'scheduled' check (status in ('scheduled', 'sending', 'done', 'cancelled')),
  scheduled_at timestamptz not null default now(),
  started_at timestamptz,
  finished_at timestamptz,
  locked_until timestamptz,
  created_by uuid references public.tenant_members(id) on delete set null,
  created_at timestamptz not null default now()
);
create index wa_campaigns_tenant on public.wa_campaigns (tenant_id, created_at desc);
create index wa_campaigns_due on public.wa_campaigns (scheduled_at) where status in ('scheduled', 'sending');

create table public.wa_campaign_recipients (
  id uuid primary key default gen_random_uuid(),
  campaign_id uuid not null references public.wa_campaigns(id) on delete cascade,
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  phone text not null,
  name text,
  lead_id uuid references public.leads(id) on delete set null,
  params jsonb not null default '{}'::jsonb,
  status text not null default 'queued' check (status in ('queued', 'sent', 'failed', 'cancelled')),
  error text,
  log_id uuid references public.whatsapp_logs(id) on delete set null,
  sent_at timestamptz,
  unique (campaign_id, phone)
);
create index wa_campaign_recipients_queue on public.wa_campaign_recipients (campaign_id, status);

alter table public.whatsapp_logs add column campaign_id uuid references public.wa_campaigns(id) on delete set null;
alter table public.whatsapp_logs drop constraint whatsapp_logs_source_check;
alter table public.whatsapp_logs add constraint whatsapp_logs_source_check check (source in ('workflow', 'app', 'reply', 'campaign'));

alter table public.wa_campaigns enable row level security;
alter table public.wa_campaign_recipients enable row level security;
create policy "wa_campaigns: read" on public.wa_campaigns
  for select to authenticated using (private.has_permission(tenant_id, 'whatsapp', 'campaign'));
create policy "wa_campaign_recipients: read" on public.wa_campaign_recipients
  for select to authenticated using (private.has_permission(tenant_id, 'whatsapp', 'campaign'));

-- the sender (wa-campaign edge function)
create or replace function private.kick_wa_campaigns()
returns void language sql security definer set search_path to '' as $$
  select net.http_post(
    url := 'https://tnnjudehqalkgglzkfik.supabase.co/functions/v1/wa-campaign',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-secret', public.workflow_cron_secret()),
    body := '{"action":"cron"}'::jsonb,
    timeout_milliseconds := 55000
  );
$$;

/**
 * a new campaign: p_campaign { name, template, template_language, template_body, audience, scheduled_at (null = now) },
 * p_recipients [{ phone (country code, digits), name, lead_id, params }] — one per number
 */
create or replace function public.wa_campaign_create(p_tenant uuid, p_campaign jsonb, p_recipients jsonb)
returns uuid language plpgsql security definer set search_path to '' as $$
declare
  v_id uuid;
  v_at timestamptz := coalesce(nullif(p_campaign ->> 'scheduled_at', '')::timestamptz, now());
  v_n int;
begin
  if not private.has_permission(p_tenant, 'whatsapp', 'campaign') then
    raise exception 'Your role can''t send WhatsApp campaigns.';
  end if;
  if coalesce(trim(p_campaign ->> 'template'), '') = '' then raise exception 'Pick a template.'; end if;
  if v_at < now() - interval '5 minutes' then raise exception 'The schedule time has passed.'; end if;

  insert into public.wa_campaigns (tenant_id, name, template, template_language, template_body, audience, scheduled_at, created_by)
  values (
    p_tenant,
    coalesce(nullif(trim(p_campaign ->> 'name'), ''), p_campaign ->> 'template'),
    trim(p_campaign ->> 'template'),
    nullif(p_campaign ->> 'template_language', ''),
    p_campaign ->> 'template_body',
    coalesce(p_campaign -> 'audience', '{}'::jsonb),
    v_at,
    private.my_member_id(p_tenant)
  )
  returning id into v_id;

  insert into public.wa_campaign_recipients (campaign_id, tenant_id, phone, name, lead_id, params)
  select v_id, p_tenant, r.phone, nullif(trim(r.name), ''),
         (select l.id from public.leads l where l.id = r.lead_id and l.tenant_id = p_tenant),
         coalesce(r.params, '{}'::jsonb)
  from jsonb_to_recordset(coalesce(p_recipients, '[]'::jsonb)) as r(phone text, name text, lead_id uuid, params jsonb)
  where r.phone ~ '^[0-9]{11,15}$'
  on conflict (campaign_id, phone) do nothing;

  get diagnostics v_n = row_count;
  if v_n = 0 then raise exception 'No valid numbers to send to.'; end if;
  update public.wa_campaigns set total = v_n where id = v_id;

  if v_at <= now() then perform private.kick_wa_campaigns(); end if;
  return v_id;
end
$$;
revoke all on function public.wa_campaign_create(uuid, jsonb, jsonb) from public, anon;
grant execute on function public.wa_campaign_create(uuid, jsonb, jsonb) to authenticated;

/** Cancel: a scheduled campaign, or the rest of one that is sending */
create or replace function public.wa_campaign_cancel(p_id uuid)
returns void language plpgsql security definer set search_path to '' as $$
declare v_tenant uuid;
begin
  select tenant_id into v_tenant from public.wa_campaigns where id = p_id;
  if v_tenant is null or not private.has_permission(v_tenant, 'whatsapp', 'campaign') then
    raise exception 'Your role can''t cancel WhatsApp campaigns.';
  end if;
  update public.wa_campaigns set status = 'cancelled', finished_at = now() where id = p_id and status in ('scheduled', 'sending');
  update public.wa_campaign_recipients set status = 'cancelled' where campaign_id = p_id and status = 'queued';
end
$$;
revoke all on function public.wa_campaign_cancel(uuid) from public, anon;
grant execute on function public.wa_campaign_cancel(uuid) to authenticated;

/**
 * each recipient's state: queued / cancelled / failed / sent (not delivered yet) / delivered / read,
 * and the first reply from that number within 7 days of the send
 */
create or replace function public.wa_campaign_people(p_tenant uuid, p_ids uuid[])
returns table (id uuid, campaign_id uuid, phone text, name text, lead_id uuid, state text, error text,
               sent_at timestamptz, delivered_at timestamptz, read_at timestamptz, replied_at timestamptz)
language sql stable security definer set search_path to '' as $$
  select r.id, r.campaign_id, r.phone, r.name, r.lead_id,
    case
      when r.status in ('queued', 'cancelled', 'failed') then r.status
      when g.status = 'failed' then 'failed'
      when g.status = 'read' or g.read_at is not null then 'read'
      when g.status = 'delivered' or g.delivered_at is not null then 'delivered'
      else 'sent'
    end,
    coalesce(r.error, g.error), r.sent_at, g.delivered_at, g.read_at,
    (select min(i.sent_at) from public.whatsapp_logs i
      where i.tenant_id = r.tenant_id and i.direction = 'in' and i.phone = r.phone
        and i.sent_at > r.sent_at and i.sent_at < r.sent_at + interval '7 days')
  from public.wa_campaign_recipients r
  left join public.whatsapp_logs g on g.id = r.log_id
  where r.tenant_id = p_tenant and r.campaign_id = any(p_ids)
    and private.has_permission(p_tenant, 'whatsapp', 'campaign')
$$;
revoke all on function public.wa_campaign_people(uuid, uuid[]) from public, anon;
grant execute on function public.wa_campaign_people(uuid, uuid[]) to authenticated;

/** the counts for the campaigns list */
create or replace function public.wa_campaign_stats(p_tenant uuid, p_ids uuid[])
returns table (campaign_id uuid, total int, queued int, sent int, delivered int, seen int, replied int, failed int, cancelled int)
language sql stable security definer set search_path to '' as $$
  select p.campaign_id,
    count(*)::int,
    count(*) filter (where p.state = 'queued')::int,
    count(*) filter (where p.state in ('sent', 'delivered', 'read'))::int,
    count(*) filter (where p.state in ('delivered', 'read'))::int,
    count(*) filter (where p.state = 'read')::int,
    count(*) filter (where p.replied_at is not null)::int,
    count(*) filter (where p.state = 'failed')::int,
    count(*) filter (where p.state = 'cancelled')::int
  from public.wa_campaign_people(p_tenant, p_ids) p
  group by p.campaign_id
$$;
revoke all on function public.wa_campaign_stats(uuid, uuid[]) from public, anon;
grant execute on function public.wa_campaign_stats(uuid, uuid[]) to authenticated;

/** for the sender only: the next due campaign, locked for 90 seconds */
create or replace function public.wa_campaign_claim()
returns setof public.wa_campaigns language sql security definer set search_path to '' as $$
  update public.wa_campaigns c
     set status = 'sending', started_at = coalesce(c.started_at, now()), locked_until = now() + interval '90 seconds'
   where c.id = (
     select x.id from public.wa_campaigns x
      where x.status in ('scheduled', 'sending') and x.scheduled_at <= now()
        and (x.locked_until is null or x.locked_until < now())
      order by x.scheduled_at
      limit 1
      for update skip locked)
  returning c.*
$$;
revoke all on function public.wa_campaign_claim() from public, anon, authenticated;
grant execute on function public.wa_campaign_claim() to service_role;

-- every minute while a campaign is due (a send-now campaign is also kicked when it's made)
select cron.schedule('wa-campaigns', '* * * * *', $$
  select private.kick_wa_campaigns()
  where exists (select 1 from public.wa_campaigns where status in ('scheduled', 'sending') and scheduled_at <= now()
                  and (locked_until is null or locked_until < now()));
$$);
