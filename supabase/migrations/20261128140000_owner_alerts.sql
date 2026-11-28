-- Dashboard (owner) → Alerts, live: connections with an error, team members / callers idle for 3+ hours in working
-- time (10 am – 8 pm India time, once they've started for the day), new leads waiting over an hour for the first
-- call, campaigns that spent with no leads yesterday, failed WhatsApp messages, Zoom meetings not created and
-- recordings not copied. Each: { level: bad | warn, kind, text, to }. Only the owner / admins.
create or replace function public.owner_alerts(p_tenant uuid, p_business uuid default null)
returns jsonb
language sql stable security definer set search_path = '' as $$
  with b as (
    select now() at time zone 'Asia/Kolkata' ist,
           (now() at time zone 'Asia/Kolkata')::date today,
           ((now() at time zone 'Asia/Kolkata')::date::timestamp at time zone 'Asia/Kolkata') d0,
           extract(hour from now() at time zone 'Asia/Kolkata') between 10 and 19 working
     where private.is_owner_view(p_tenant)
  ),
  a as (
    -- connections
    select 1 o, 'bad' lvl, 'connection' kind,
           initcap(replace(i.provider, '_', ' ')) || coalesce(' · ' || nullif(i.label, ''), '') || ': ' || coalesce(nullif(i.last_error, ''), 'not connected') txt,
           '/integrations' dest
      from public.integrations i, b
     where i.tenant_id = p_tenant and i.is_enabled and (i.status = 'error' or nullif(i.last_error, '') is not null)
    union all
    select 1, 'bad', 'connection', 'Facebook ad account ' || x.name || ': ' || x.last_error, '/integrations/facebook-ads/logs'
      from public.meta_ad_accounts x, b where x.tenant_id = p_tenant and x.is_enabled and nullif(x.last_error, '') is not null
    union all
    select 1, 'bad', 'connection', 'Google Ads account ' || x.name || ': ' || x.last_error, '/integrations/google-ads/logs'
      from public.google_ad_accounts x, b where x.tenant_id = p_tenant and x.is_enabled and nullif(x.last_error, '') is not null
    -- callers (Callyzer) quiet for 3+ hours today, after calling earlier
    union all
    select 2, 'warn', 'idle',
           coalesce(c.name, c.emp_number) || ': no call since ' || to_char(c.last_at at time zone 'Asia/Kolkata', 'FMHH12:MI am')
             || ' (' || floor(extract(epoch from now() - c.last_at) / 3600) || 'h ' || floor(mod(extract(epoch from now() - c.last_at)::int, 3600) / 60) || 'm)',
           '/callyzer/report'
      from (select t.emp_number, (array_agg(t.emp_name order by t.started_at desc) filter (where t.emp_name is not null))[1] name, max(t.started_at) last_at
              from public.callyzer_team_calls t, b where t.tenant_id = p_tenant and t.started_at >= b.d0 group by t.emp_number) c, b
     where b.working and c.last_at < now() - interval '3 hours'
    -- team members: follow-ups due today but nothing logged for 3+ hours
    union all
    select 2, 'warn', 'idle',
           m.name || case when m.last_done is null then ': ' || m.due_today || ' follow-ups due or overdue, none logged today'
                          else ': no follow-up logged since ' || to_char(m.last_done at time zone 'Asia/Kolkata', 'FMHH12:MI am') || ' (' || m.due_today || ' due or overdue)' end,
           '/reports/team'
      from (select tm.id, coalesce(p.full_name, p.email) name,
                   (select max(f.completed_at) from public.follow_ups f where f.completed_by = tm.id and f.status = 'done' and f.completed_at >= b.d0) last_done,
                   (select count(*) from public.follow_ups f join public.leads l on l.id = f.lead_id
                     where f.assigned_to = tm.id and f.status = 'pending' and f.due_at < b.d0 + interval '1 day'
                       and (p_business is null or l.business_id = p_business)) due_today
              from public.tenant_members tm join public.profiles p on p.id = tm.user_id, b
             where tm.tenant_id = p_tenant and tm.status = 'active' and not coalesce(tm.is_support, false)) m, b
     where b.working and m.due_today > 0
       and ((m.last_done is null and extract(hour from b.ist) >= 13) or m.last_done < now() - interval '3 hours')
    -- new leads waiting for the first call
    union all
    select 3, 'warn', 'leads', count(*) || ' new lead' || case when count(*) = 1 then '' else 's' end || ' waiting over an hour for the first call', '/leads'
      from public.leads l, b
     where l.tenant_id = p_tenant and not coalesce(l.is_archived, false) and l.created_at >= b.d0 and l.created_at < now() - interval '1 hour'
       and coalesce(l.temperature, '') not in ('not_interested', 'closed') and (p_business is null or l.business_id = p_business)
       and not exists (select 1 from public.follow_ups f where f.lead_id = l.id and f.status = 'done')
       and not exists (select 1 from public.calls c where c.lead_id = l.id)
    having count(*) > 0
    -- campaigns that spent ₹1,000+ yesterday with no leads
    union all
    select 4, 'warn', 'ads', '“' || s.name || '” spent ₹' || to_char(round(s.spend), 'FM99,99,999') || ' yesterday with no leads', '/funnels'
      from (select coalesce(c.name, mi.campaign_id) name, sum(mi.spend * (1 + coalesce(a.gst_rate, 18) / 100)) spend
              from public.meta_insights mi join public.meta_ad_accounts a on a.id = mi.account_id
              left join public.meta_campaigns c on c.tenant_id = mi.tenant_id and c.campaign_id = mi.campaign_id, b
             where mi.tenant_id = p_tenant and mi.day = b.today - 1 group by 1) s, b
     where s.spend >= 1000
       and not exists (select 1 from public.leads l where l.tenant_id = p_tenant and l.ad_campaign = s.name
                         and (l.created_at at time zone 'Asia/Kolkata')::date = b.today - 1)
    -- WhatsApp
    union all
    select 5, 'warn', 'whatsapp', count(*) || ' WhatsApp message' || case when count(*) = 1 then '' else 's' end || ' failed in the last 24 hours', '/whatsapp/logs'
      from public.whatsapp_logs w where w.tenant_id = p_tenant and w.status = 'failed' and w.sent_at > now() - interval '24 hours'
    having count(*) > 0
    -- Zoom
    union all
    select 6, 'bad', 'zoom', 'Zoom meeting not created for the meeting on ' || to_char(m.meeting_date, 'FMDD Mon') || ': ' || m.zoom_error, '/meetings'
      from public.meetings m, b
     where m.tenant_id = p_tenant and m.status = 'scheduled' and m.meeting_date >= b.today and nullif(m.zoom_error, '') is not null
       and (p_business is null or m.business_id = p_business)
    union all
    select 6, 'warn', 'recording', count(*) || ' meeting recording' || case when count(*) = 1 then '' else 's' end || ' couldn’t be copied (last 3 days)', '/meetings'
      from public.meeting_recordings r where r.tenant_id = p_tenant and r.copy_status = 'error' and r.created_at > now() - interval '3 days'
    having count(*) > 0
  )
  select case when not exists (select 1 from b) then null
         else coalesce((select jsonb_agg(jsonb_build_object('level', lvl, 'kind', kind, 'text', txt, 'to', dest) order by o, lvl, txt) from a), '[]'::jsonb) end
$$;
revoke all on function public.owner_alerts(uuid, uuid) from public, anon;
grant execute on function public.owner_alerts(uuid, uuid) to authenticated;
