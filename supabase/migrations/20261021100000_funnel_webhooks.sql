-- Webhooks belong to the funnel, not to a landing page.
-- A funnel has many landing pages and many webhooks, with no link between them.
-- Existing webhook URLs (keys) keep working.

alter table public.landing_page_webhooks rename to funnel_webhooks;
alter table public.funnel_webhooks add column funnel_id uuid references public.funnels (id) on delete cascade;
update public.funnel_webhooks w
set funnel_id = p.funnel_id,
    name = case when w.name = 'Main form' then p.name else p.name || ' · ' || w.name end
from public.landing_pages p
where p.id = w.landing_page_id;
alter table public.funnel_webhooks alter column funnel_id set not null;

-- the old landing page link is kept (no longer used) so nothing is removed
alter table public.funnel_webhooks alter column landing_page_id drop not null;
create index funnel_webhooks_funnel_idx on public.funnel_webhooks (funnel_id);

alter policy "landing_page_webhooks: read" on public.funnel_webhooks rename to "funnel_webhooks: read";
alter policy "landing_page_webhooks: write" on public.funnel_webhooks rename to "funnel_webhooks: write";
alter policy "funnel_webhooks: read" on public.funnel_webhooks
  using (exists (select 1 from public.funnels f where f.id = funnel_webhooks.funnel_id
                 and (private.can_access_business(f.business_id) or private.has_permission(f.tenant_id, 'funnels', 'view'))));

-- a new landing page no longer gets a webhook (trigger switched off, not removed)
alter table public.landing_pages disable trigger landing_pages_first_webhook;

-- which webhook a lead / submission came through
alter table public.leads add column webhook_id uuid references public.funnel_webhooks (id) on delete set null;
alter table public.lead_submissions add column webhook_id uuid references public.funnel_webhooks (id) on delete set null;
create index lead_submissions_webhook_idx on public.lead_submissions (webhook_id);

-- ingest_lead(): new overload with p_webhook (stored on the lead and the submission, named in the activity);
-- the old 7-argument version (imports) calls it with no webhook.
do $$
declare
  d text := pg_get_functiondef('private.ingest_lead(uuid,uuid,uuid,jsonb,text,boolean,uuid)'::regprocedure);
  r text[][] := array[
    array['ingest_lead(p_business uuid, p_funnel uuid, p_page uuid, d jsonb', 'ingest_lead(p_business uuid, p_funnel uuid, p_page uuid, p_webhook uuid, d jsonb'],
    array['select name into pg_name from public.landing_pages where id = p_page;',
          'select coalesce((select w.name from public.funnel_webhooks w where w.id = p_webhook), (select lp.name from public.landing_pages lp where lp.id = p_page)) into pg_name;'],
    array['src, v_tags, p_page,', 'src, v_tags, p_page, p_webhook,'],
    array['source_id, tags, landing_page_id, utm_source', 'source_id, tags, landing_page_id, webhook_id, utm_source'],
    array['landing_page_id = coalesce(p_page, l.landing_page_id),', E'landing_page_id = coalesce(p_page, l.landing_page_id),\n      webhook_id = coalesce(p_webhook, l.webhook_id),'],
    array['lead_submissions (tenant_id, lead_id, funnel_id, landing_page_id, via', 'lead_submissions (tenant_id, lead_id, funnel_id, landing_page_id, webhook_id, via'],
    array['values (f.tenant_id, lid, f.id, p_page, p_via', 'values (f.tenant_id, lid, f.id, p_page, p_webhook, p_via']
  ];
  i int;
begin
  for i in 1 .. array_length(r, 1) loop
    if position(r[i][1] in d) = 0 then raise exception 'ingest_lead patch % did not apply', i; end if;
    d := replace(d, r[i][1], r[i][2]);
  end loop;
  d := replace(d, 'coalesce(pg_name, ''a landing page'')', 'coalesce(pg_name, ''a form'')');
  execute d;
end $$;
revoke all on function private.ingest_lead(uuid, uuid, uuid, uuid, jsonb, text, boolean, uuid) from public, anon;

create or replace function private.ingest_lead(p_business uuid, p_funnel uuid, p_page uuid, d jsonb, p_via text, p_add_tags boolean, p_actor uuid)
returns jsonb
language sql
security definer
set search_path = ''
as $$ select private.ingest_lead(p_business, p_funnel, p_page, null::uuid, d, p_via, p_add_tags, p_actor) $$;

create or replace function public.webhook_submit(p_key text, p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  w    public.funnel_webhooks;
  d    jsonb;
  miss text[] := '{}';
begin
  select wh.* into w from public.funnel_webhooks wh
  join public.funnels f on f.id = wh.funnel_id and f.is_active
  where wh.webhook_key = p_key and wh.is_active;
  if w.id is null then raise exception 'Unknown or inactive webhook key.'; end if;

  if w.test_mode_until is not null and w.test_mode_until > now() then
    update public.funnel_webhooks
    set sample = coalesce(p_data, '{}') - 'key' - '_redirect' - 'redirect', sample_at = now(), test_mode_until = null
    where id = w.id;
    return jsonb_build_object('status', 'test', 'message', 'Test received. Map the fields in the app.');
  end if;

  d := private.map_lead_fields(coalesce(p_data, '{}') - 'key' - '_redirect' - 'redirect', w.field_map);
  if coalesce(d ->> 'name', '') = '' and coalesce(d ->> 'first_name', '') <> '' then
    d := d || jsonb_build_object('name', trim(concat_ws(' ', d ->> 'first_name', d ->> 'last_name')));
  end if;
  d := d - 'first_name' - 'last_name';

  if coalesce(d ->> 'name', '') = '' then miss := miss || 'name'; end if;
  if coalesce(d ->> 'email', '') = '' then miss := miss || 'email'; end if;
  if coalesce(d ->> 'phone', '') = '' then miss := miss || 'phone'; end if;
  if array_length(miss, 1) > 0 then raise exception 'Missing required field(s): %', array_to_string(miss, ', '); end if;
  if (d ->> 'email') !~ '^[^\s@]+@[^\s@]+\.[^\s@]+$' then raise exception 'Enter a valid email.'; end if;
  if length(private.norm_phone(d ->> 'phone')) < 10 then raise exception 'Enter a valid phone number (10 digits).'; end if;

  return private.ingest_lead(null, w.funnel_id, null, w.id, d, 'webhook', true, null);
end;
$$;
