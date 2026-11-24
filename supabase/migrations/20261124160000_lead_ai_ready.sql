-- Lead AI Insights: the worker runs for a workspace when lead summaries are on (Gemini AI → Prompt & steps) and it has
-- Gemini connected, or Claude connected as the fallback (when Gemini is "not connected").
create or replace function private.lead_ai_ready(t uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  with g as (
    select config from public.integrations
     where tenant_id = t and provider = 'gemini' and is_enabled
     order by updated_at desc limit 1
  )
  select coalesce((select config->>'li_on' from g), 'on') <> 'off'
     and (
       exists (select 1 from g where coalesce(config->>'api_key', '') <> '')
       or (coalesce((select config->>'li_fallback' from g), 'on') <> 'off'
           and coalesce((select config->>'li_when' from g), 'not_connected') like '%not_connected%'
           and exists (select 1 from public.integrations where tenant_id = t and provider = 'claude' and is_enabled and coalesce(config->>'api_key', '') <> ''))
     )
$$;

create or replace function public.lead_insight_claim(p_limit int, p_mode text, p_tenant uuid) returns setof uuid
language plpgsql volatile security definer set search_path = '' as $$
begin
  if p_mode = 'auto' then
    return query
    update public.lead_insights i set lease = now() + interval '2 minutes'
     where i.lead_id in (
       select x.lead_id from public.lead_insights x
        where x.stale and x.tries < 3 and x.stale_at < now() - interval '1 minute'
          and (x.lease is null or x.lease < now()) and private.lead_ai_ready(x.tenant_id)
        order by x.stale_at
        limit p_limit
        for update skip locked)
    returning i.lead_id;
  else
    return query
    insert into public.lead_insights (lead_id, tenant_id, stale, stale_at, lease)
    select l.id, l.tenant_id, true, now(), now() + interval '2 minutes'
      from public.leads l
     where l.tenant_id = p_tenant and not coalesce(l.is_archived, false)
       and not exists (select 1 from public.lead_insights i
                        where i.lead_id = l.id and (i.content is not null or i.tries >= 3 or i.lease > now()))
     order by l.created_at desc
     limit p_limit
    on conflict (lead_id) do update set lease = excluded.lease
    returning lead_id;
  end if;
end $$;

select cron.unschedule('lead-insight') where exists (select 1 from cron.job where jobname = 'lead-insight');
select cron.schedule('lead-insight', '* * * * *', $c$
  select private.kick_lead_insight()
  where exists (select 1 from public.lead_insight_syncs where active)
     or exists (select 1 from public.lead_insights x
                where x.stale and x.tries < 3 and x.stale_at < now() - interval '1 minute'
                  and (x.lease is null or x.lease < now()) and private.lead_ai_ready(x.tenant_id));
$c$);
