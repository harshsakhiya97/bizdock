-- Everything on a lead goes by its number (a number that is a lead in two businesses shows its calls / WhatsApp on both),
-- Callyzer logs follow the top-bar business, a "Call logs" permission (Access Control), and calls readable only by
-- whoever can see a lead with that number (or has Call logs / Settings).

-- a lead's 10-digit number, indexed (calls and WhatsApp are matched on it)
create or replace function private.ph10(p text) returns text language sql immutable set search_path = '' as $$
  select right(regexp_replace(coalesce(p, ''), '\D', '', 'g'), 10)
$$;
create index if not exists leads_tenant_ph10 on public.leads (tenant_id, private.ph10(phone));
create index if not exists whatsapp_logs_tenant_ph10 on public.whatsapp_logs (tenant_id, private.ph10(phone), sent_at desc);

-- calls: Call logs / Settings people see all; others only calls to a number that is a lead they can see
drop policy if exists "calls: read" on public.calls;
create policy "calls: read" on public.calls for select to authenticated using (
  private.has_permission(tenant_id, 'call_logs', 'view')
  or private.has_permission(tenant_id, 'settings', 'edit')
  or exists (select 1 from public.leads l where l.tenant_id = calls.tenant_id and private.ph10(l.phone) = calls.phone)
);

-- WhatsApp (WATI) messages on a lead: by the lead's number, not only the lead it was linked to
drop policy if exists "whatsapp_logs: lead read" on public.whatsapp_logs;
create policy "whatsapp_logs: lead read" on public.whatsapp_logs for select to authenticated using (
  exists (select 1 from public.leads l where l.tenant_id = whatsapp_logs.tenant_id and private.ph10(l.phone) = private.ph10(whatsapp_logs.phone))
);

-- Callyzer logs page: calls to numbers that are leads in the picked business (and sub-business), with that lead
create or replace function public.callyzer_logs(p_tenant uuid, p_business uuid, p_sub uuid, p_from timestamptz, p_to timestamptz)
returns table (
  id uuid, phone text, direction text, started_at timestamptz, duration_sec int, call_method text, emp_name text,
  agent_phone text, recording_url text, lead_id uuid, lead_name text
)
language sql stable security definer set search_path = '' as $$
  select c.id, c.phone, c.direction, c.started_at, c.duration_sec, c.call_method, c.emp_name, c.agent_phone, c.recording_url,
         l.id, nullif(btrim(concat_ws(' ', l.first_name, l.last_name)), '')
    from public.calls c
    left join lateral (
      select l.id, l.first_name, l.last_name from public.leads l
       where l.tenant_id = c.tenant_id and private.ph10(l.phone) = c.phone
         and (p_business is null or l.business_id = p_business)
         and (p_sub is null or l.sub_business_id = p_sub)
       order by l.created_at desc limit 1) l on true
   where c.tenant_id = p_tenant and c.source = 'callyzer'
     and c.started_at >= p_from and c.started_at <= p_to
     and (private.has_permission(p_tenant, 'call_logs', 'view') or private.has_permission(p_tenant, 'settings', 'edit'))
     and (p_business is null or l.id is not null)
   order by c.started_at desc
   limit 5000;
$$;
revoke all on function public.callyzer_logs(uuid, uuid, uuid, timestamptz, timestamptz) from public, anon;
grant execute on function public.callyzer_logs(uuid, uuid, uuid, timestamptz, timestamptz) to authenticated;

-- leads lists of every business: Callyzer calls per lead (by number): total and connected
create or replace function public.lead_call_counts(p_tenant uuid, p_leads uuid[])
returns table (lead_id uuid, total int, connected int)
language sql stable security definer set search_path = '' as $$
  with l as (
    select l.id, private.ph10(l.phone) as ph from public.leads l
     where l.tenant_id = p_tenant and l.id = any (p_leads)
       and private.can_see_lead(l.tenant_id, l.business_id, l.owner_id)
  ), c as (
    select k.phone, count(*) as total, count(*) filter (where coalesce(k.duration_sec, 0) > 0) as connected
      from public.calls k
     where k.tenant_id = p_tenant and k.phone in (select ph from l where length(ph) = 10)
     group by k.phone
  )
  select l.id, c.total::int, c.connected::int from l join c on c.phone = l.ph;
$$;
revoke all on function public.lead_call_counts(uuid, uuid[]) from public, anon;
grant execute on function public.lead_call_counts(uuid, uuid[]) to authenticated;
