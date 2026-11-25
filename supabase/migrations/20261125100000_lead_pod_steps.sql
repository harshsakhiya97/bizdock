-- Leads (Paid Podcast) → Funnel step filter: per lead, whether it sent a VSL form (Webhooks → Form step: VSL) and its
-- meetings (booked = any not cancelled, done, no-show). Runs as the caller (row security). The same steps as the
-- Paid Podcast Scorecard (src/funnels/podSteps.ts).
create or replace function public.lead_pod_steps(p_tenant uuid)
returns table (lead_id uuid, vsl boolean, booked boolean, done boolean, noshow boolean)
language sql stable set search_path = '' as $$
  with v as (
    select distinct s.lead_id from public.lead_submissions s
      join public.funnel_webhooks w on w.id = s.webhook_id
     where s.tenant_id = p_tenant and w.step = 'vsl' and s.lead_id is not null
  ),
  m as (
    select mt.lead_id, bool_or(mt.status <> 'cancelled') booked, bool_or(mt.status = 'done') done, bool_or(mt.status = 'no_show') noshow
      from public.meetings mt
     where mt.tenant_id = p_tenant and mt.lead_id is not null
     group by mt.lead_id
  )
  select coalesce(v.lead_id, m.lead_id), v.lead_id is not null, coalesce(m.booked, false), coalesce(m.done, false), coalesce(m.noshow, false)
    from v full join m on m.lead_id = v.lead_id
$$;
revoke all on function public.lead_pod_steps(uuid) from public, anon;
grant execute on function public.lead_pod_steps(uuid) to authenticated;
