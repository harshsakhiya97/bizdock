-- Lead → Source from utm_source, and the ad it came from (More Fields: Source, Campaign Name, Adset Name, Ad Name,
-- fbclid, gclid).
--  * Source: utm_source decides it (the form's "Website" is ignored). Known codes from a list (ig → Instagram, fb →
--    Facebook, …; source_aliases has the workspace's own); a new code waits in leads.utm_source_pending and the AI
--    decides it on the lead's next AI Insights run (lead-insight → lead_source_resolve), saved to source_aliases.
--  * Names from the IDs in the lead's fields / page URL: utm_id → campaign, utm_term (ad set id) → ad set,
--    h_ad_id / ad_id → ad, looked up in the synced Facebook / Google data; else utm_campaign / utm_medium / utm_content.
--  * A Google Sheet lead with no ad info: Source Google Sheet, Campaign Name = the sheet's name.
-- Worked out when a lead comes in (or its UTMs / fields change); every lead filled once below.

alter table public.leads add column if not exists ad_campaign text;
alter table public.leads add column if not exists ad_adset text;
alter table public.leads add column if not exists ad_name text;
alter table public.leads add column if not exists fbclid text;
alter table public.leads add column if not exists gclid text;
alter table public.leads add column if not exists utm_source_pending text;

create table if not exists public.source_aliases (
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  code text not null,
  source_name text not null,
  decided_by text not null default 'ai',
  created_at timestamptz not null default now(),
  primary key (tenant_id, code)
);
alter table public.source_aliases enable row level security;
create policy "source_aliases: read" on public.source_aliases for select using (private.is_member(tenant_id));
grant select on public.source_aliases to authenticated;

-- %xx and + in a URL value
create or replace function private.url_decode(s text) returns text
language plpgsql immutable set search_path = '' as $$
declare
  r bytea := '';
  i int := 1;
  c text;
begin
  if s is null then return null; end if;
  s := replace(s, '+', ' ');
  while i <= length(s) loop
    c := substr(s, i, 1);
    if c = '%' and substr(s, i + 1, 2) ~ '^[0-9A-Fa-f]{2}$' then
      r := r || decode(substr(s, i + 1, 2), 'hex');
      i := i + 3;
    else
      r := r || convert_to(c, 'UTF8');
      i := i + 1;
    end if;
  end loop;
  return convert_from(r, 'UTF8');
exception when others then
  return s;
end $$;

create or replace function private.url_param(p_url text, p_key text) returns text
language sql immutable set search_path = '' as $$
  select nullif(trim(private.url_decode((regexp_match(coalesce(p_url, ''), '[?&]' || p_key || '=([^&#]*)'))[1])), '')
$$;

-- a utm_source code → a Source name (null: not known yet)
create or replace function private.source_for_code(p_tenant uuid, p_code text) returns text
language plpgsql stable security definer set search_path = '' as $$
declare
  c text := lower(trim(coalesce(p_code, '')));
  v text;
begin
  if c = '' or c like '%{{%' then return null; end if;
  select a.source_name into v from public.source_aliases a where a.tenant_id = p_tenant and a.code = c;
  if v is not null then return v; end if;
  v := case
    when c in ('ig', 'insta', 'instagram') then 'Instagram'
    when c in ('fb', 'facebook') then 'Facebook'
    when c in ('google', 'gads', 'adwords', 'google_ads', 'googleads') then 'Google'
    when c in ('yt', 'youtube') then 'YouTube'
    when c in ('wa', 'whatsapp') then 'WhatsApp'
  end;
  if v is not null then return v; end if;
  -- the code is already a Source's name (e.g. "Facebook")
  select s.name into v from public.lead_sources s where s.tenant_id = p_tenant and lower(s.name) = c limit 1;
  return v;
end $$;

-- a Source by name (added to the workspace's Sources when missing)
create or replace function private.source_id_named(p_tenant uuid, p_name text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v uuid;
begin
  select id into v from public.lead_sources where tenant_id = p_tenant and lower(name) = lower(p_name) limit 1;
  if v is null then
    insert into public.lead_sources (tenant_id, name, sort_order)
    values (p_tenant, p_name, coalesce((select max(sort_order) + 1 from public.lead_sources where tenant_id = p_tenant), 1))
    on conflict (tenant_id, name) do nothing returning id into v;
    if v is null then select id into v from public.lead_sources where tenant_id = p_tenant and name = p_name; end if;
  end if;
  return v;
end $$;

-- fills a lead's ad fields (and, when p_source, its Source) from its UTMs, fields and page URL
create or replace function private.lead_ad_fill(l public.leads, p_source boolean) returns public.leads
language plpgsql security definer set search_path = '' as $$
declare
  pu text := coalesce(l.extra ->> 'page_url', '');
  ru text := coalesce(l.extra ->> 'redirect_url', '');
  cid text;
  sid text;
  aid text;
  v text;
  code text;
  num text := '^\d{6,}$';
begin
  -- a value from the lead's fields, else the page URL, else the redirect URL
  cid := coalesce(nullif(l.extra ->> 'utm_id', ''), nullif(l.extra ->> 'campaign_id', ''), private.url_param(pu, 'utm_id'), private.url_param(ru, 'utm_id'),
                  private.url_param(pu, 'campaign_id'), private.url_param(pu, 'gad_campaignid'),
                  case when l.utm_campaign ~ num then l.utm_campaign end);
  sid := coalesce(nullif(l.extra ->> 'adset_id', ''), case when l.utm_term ~ num then l.utm_term end,
                  case when private.url_param(pu, 'utm_term') ~ num then private.url_param(pu, 'utm_term') end,
                  private.url_param(pu, 'adset_id'), private.url_param(pu, 'adgroupid'));
  aid := coalesce(nullif(l.extra ->> 'ad_id', ''), nullif(l.extra ->> 'h_ad_id', ''), private.url_param(pu, 'h_ad_id'), private.url_param(pu, 'ad_id'),
                  private.url_param(ru, 'h_ad_id'), case when l.utm_content ~ num then l.utm_content end);
  l.fbclid := coalesce(nullif(l.extra ->> 'fbclid', ''), private.url_param(pu, 'fbclid'), private.url_param(ru, 'fbclid'));
  l.gclid := coalesce(nullif(l.extra ->> 'gclid', ''), private.url_param(pu, 'gclid'), private.url_param(ru, 'gclid'));

  v := null;
  if cid is not null then
    select c.name into v from public.meta_campaigns c where c.tenant_id = l.tenant_id and c.campaign_id = cid;
    if v is null then select c.name into v from public.google_campaigns c where c.tenant_id = l.tenant_id and c.campaign_id = cid; end if;
  end if;
  l.ad_campaign := coalesce(v, case when l.utm_campaign !~ num then nullif(trim(l.utm_campaign), '') end);

  v := null;
  if sid is not null then
    select s.name into v from public.meta_adsets s where s.tenant_id = l.tenant_id and s.adset_id = sid;
    if v is null then select g.name into v from public.google_ad_groups g where g.tenant_id = l.tenant_id and g.ad_group_id = sid; end if;
  end if;
  l.ad_adset := coalesce(v, case when l.utm_medium !~ num then nullif(trim(l.utm_medium), '') end);

  v := null;
  if aid is not null then
    select a.name into v from public.meta_ads a where a.tenant_id = l.tenant_id and a.ad_id = aid;
    if v is null then select a.name into v from public.google_ads a where a.tenant_id = l.tenant_id and a.ad_id = aid; end if;
  end if;
  l.ad_name := coalesce(v, case when l.utm_content !~ num then nullif(trim(l.utm_content), '') end);

  -- a Google Sheet lead with no ad info: the sheet's name as the campaign
  if l.sheet_id is not null and l.ad_campaign is null and l.ad_adset is null and l.ad_name is null and coalesce(l.utm_source, '') = '' then
    select s.name into l.ad_campaign from public.funnel_sheets s where s.id = l.sheet_id;
  end if;

  if p_source then
    code := coalesce(nullif(trim(l.utm_source), ''), private.url_param(pu, 'utm_source'));
    if code is not null and code not like '%{{%' then
      v := private.source_for_code(l.tenant_id, code);
      if v is not null then
        l.source_id := private.source_id_named(l.tenant_id, v);
        l.utm_source_pending := null;
      else
        l.utm_source_pending := lower(trim(code));
      end if;
    elsif l.sheet_id is not null then
      l.source_id := private.source_id_named(l.tenant_id, 'Google Sheet');
      l.utm_source_pending := null;
    end if;
  end if;
  return l;
end $$;

create or replace function private.leads_ad_info() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'UPDATE'
     and new.utm_source is not distinct from old.utm_source and new.utm_medium is not distinct from old.utm_medium
     and new.utm_campaign is not distinct from old.utm_campaign and new.utm_term is not distinct from old.utm_term
     and new.utm_content is not distinct from old.utm_content and new.extra is not distinct from old.extra
     and new.sheet_id is not distinct from old.sheet_id then
    return new;
  end if;
  -- the Source only when the lead comes in, its utm_source changes, or it's first tied to a sheet
  return private.lead_ad_fill(new, tg_op = 'INSERT' or new.utm_source is distinct from old.utm_source
                                    or (old.sheet_id is null and new.sheet_id is not null));
end $$;
drop trigger if exists leads_ad_info on public.leads;
create trigger leads_ad_info before insert or update on public.leads
  for each row execute function private.leads_ad_info();

-- the AI's answer for a new code (lead-insight): saved for the workspace; every lead waiting on that code gets it
create or replace function public.lead_source_resolve(p_tenant uuid, p_code text, p_name text) returns integer
language plpgsql security definer set search_path = '' as $$
declare
  c text := lower(trim(p_code));
  n text := nullif(trim(p_name), '');
  sid uuid;
  k int;
begin
  if c = '' or n is null then return 0; end if;
  insert into public.source_aliases (tenant_id, code, source_name, decided_by) values (p_tenant, c, n, 'ai')
  on conflict (tenant_id, code) do nothing;
  select a.source_name into n from public.source_aliases a where a.tenant_id = p_tenant and a.code = c;
  sid := private.source_id_named(p_tenant, n);
  update public.leads set source_id = sid, utm_source_pending = null where tenant_id = p_tenant and utm_source_pending = c;
  get diagnostics k = row_count;
  return k;
end $$;
revoke all on function public.lead_source_resolve(uuid, text, text) from public, anon, authenticated;
grant execute on function public.lead_source_resolve(uuid, text, text) to service_role;

-- every lead once (no AI Insights rewrite, "Updated" time kept); the ones waiting on a new code are queued for AI
alter table public.leads disable trigger lead_insight_touch;
alter table public.leads disable trigger leads_set_updated_at;
alter table public.leads disable trigger leads_ad_info;
update public.leads l set
  ad_campaign = x.ad_campaign, ad_adset = x.ad_adset, ad_name = x.ad_name, fbclid = x.fbclid, gclid = x.gclid,
  source_id = x.source_id, utm_source_pending = x.utm_source_pending
from (select f.* from public.leads l2 cross join lateral private.lead_ad_fill(l2, true) f) x
where x.id = l.id;
alter table public.leads enable trigger leads_ad_info;
alter table public.leads enable trigger leads_set_updated_at;
alter table public.leads enable trigger lead_insight_touch;

insert into public.lead_insights (lead_id, tenant_id, stale, stale_at, tries, error)
select l.id, l.tenant_id, true, now(), 0, null from public.leads l where l.utm_source_pending is not null
on conflict (lead_id) do update set stale = true, stale_at = now(), tries = 0, error = null;
