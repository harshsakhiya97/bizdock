-- ============================================================
-- Funnels: tags, linked event / webinar, landing pages with a webhook each, UTM links,
-- form submissions, and lead import.
--   funnels.tags         added to every lead that comes in through the funnel
--   funnels.event_id     the webinar / event this funnel leads to (for "before the event" messages)
--   landing pages        one per page link; each has its own secret webhook key and the extra
--                        form fields it sends (name, email and phone are always required)
--   UTM links            tracking links per landing page (Facebook ad 1, Instagram story…)
--   lead_submissions     every form post / import row, kept as received
-- A form post from the same phone in the same funnel updates that lead instead of adding a new one.
-- ============================================================

alter table public.funnels
  add column tags     text[] not null default '{}',
  add column event_id uuid references public.events (id) on delete set null;

create table public.landing_pages (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null,
  funnel_id      uuid not null,
  name           text not null,
  url            text,
  webhook_key    text not null unique default replace(gen_random_uuid()::text, '-', ''),
  -- extra form fields: [{"key":"city","label":"City","required":false}, …]
  fields         jsonb not null default '[]',
  -- used when the form does not send its own utm_* values
  utm_source     text,
  utm_medium     text,
  utm_campaign   text,
  is_active      boolean not null default true,
  archived_at    timestamptz,
  sort_order     int not null default 0,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  foreign key (funnel_id, tenant_id) references public.funnels (id, tenant_id) on delete cascade
);
create index landing_pages_funnel_idx on public.landing_pages (funnel_id);
create trigger landing_pages_set_updated_at before update on public.landing_pages
  for each row execute function public.set_updated_at();

create table public.landing_page_utms (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references public.tenants (id) on delete cascade,
  landing_page_id  uuid not null references public.landing_pages (id) on delete cascade,
  label            text not null,
  utm_source       text not null,
  utm_medium       text,
  utm_campaign     text,
  utm_term         text,
  utm_content      text,
  created_at       timestamptz not null default now()
);
create index landing_page_utms_page_idx on public.landing_page_utms (landing_page_id);

alter table public.leads
  add column landing_page_id uuid references public.landing_pages (id) on delete set null,
  add column utm_source   text,
  add column utm_medium   text,
  add column utm_campaign text,
  add column utm_term     text,
  add column utm_content  text,
  add column extra        jsonb not null default '{}';   -- extra form fields (company, purpose…)

create table public.lead_submissions (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references public.tenants (id) on delete cascade,
  lead_id          uuid not null references public.leads (id) on delete cascade,
  funnel_id        uuid not null,
  landing_page_id  uuid references public.landing_pages (id) on delete set null,
  via              text not null default 'webhook' check (via in ('webhook', 'import')),
  is_new           boolean not null,          -- true = created the lead, false = updated it
  utm_source       text,
  utm_medium       text,
  utm_campaign     text,
  utm_term         text,
  utm_content      text,
  data             jsonb not null default '{}',
  created_at       timestamptz not null default now()
);
create index lead_submissions_lead_idx on public.lead_submissions (lead_id, created_at desc);
create index lead_submissions_page_idx on public.lead_submissions (landing_page_id);

alter table public.lead_activities drop constraint lead_activities_kind_check;
alter table public.lead_activities add constraint lead_activities_kind_check check (kind in (
  'created', 'stage', 'note', 'assigned', 'temperature', 'follow_up', 'archived', 'restored', 'submission', 'imported'));

-- ---------- row security ----------
alter table public.landing_pages enable row level security;
create policy "landing_pages: read" on public.landing_pages for select to authenticated
  using (exists (select 1 from public.funnels f where f.id = funnel_id
                 and (private.can_access_business(f.business_id) or private.has_permission(f.tenant_id, 'funnels', 'view'))));
create policy "landing_pages: insert" on public.landing_pages for insert to authenticated
  with check (private.has_permission(tenant_id, 'funnels', 'edit') or private.has_permission(tenant_id, 'funnels', 'add'));
create policy "landing_pages: update" on public.landing_pages for update to authenticated
  using (private.has_permission(tenant_id, 'funnels', 'edit'))
  with check (private.has_permission(tenant_id, 'funnels', 'edit'));

alter table public.landing_page_utms enable row level security;
create policy "landing_page_utms: read" on public.landing_page_utms for select to authenticated
  using (exists (select 1 from public.landing_pages p join public.funnels f on f.id = p.funnel_id
                 where p.id = landing_page_id
                   and (private.can_access_business(f.business_id) or private.has_permission(f.tenant_id, 'funnels', 'view'))));
create policy "landing_page_utms: write" on public.landing_page_utms for all to authenticated
  using (private.has_permission(tenant_id, 'funnels', 'edit'))
  with check (private.has_permission(tenant_id, 'funnels', 'edit'));

alter table public.lead_submissions enable row level security;
create policy "lead_submissions: read" on public.lead_submissions for select to authenticated
  using (exists (select 1 from public.leads l where l.id = lead_id
                 and private.can_see_lead(l.tenant_id, l.business_id, l.owner_id)));

grant select, insert, update on public.landing_pages to authenticated;
grant select, insert, update, delete on public.landing_page_utms to authenticated;
grant select on public.lead_submissions to authenticated;
revoke all on public.landing_pages, public.landing_page_utms, public.lead_submissions from anon;

-- ============================================================
-- Adding / updating a lead from a form post or an import row
-- ============================================================
create or replace function private.norm_phone(p text)
returns text language sql immutable set search_path = '' as $$
  select right(regexp_replace(coalesce(p, ''), '\D', '', 'g'), 10)
$$;

-- d: {name | first_name/last_name, email, phone, city, utm_*, …extra fields}
-- returns {"lead_id": …, "status": "created" | "updated"}
create or replace function private.ingest_lead(
  p_funnel uuid, p_page uuid, d jsonb, p_via text, p_add_tags boolean, p_actor uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  f        public.funnels;
  pg_name  text;
  st       uuid;
  lid      uuid;
  fname    text;
  lname    text;
  full_n   text := nullif(trim(coalesce(d ->> 'name', '')), '');
  ph       text := nullif(trim(coalesce(d ->> 'phone', '')), '');
  em       text := nullif(lower(trim(coalesce(d ->> 'email', ''))), '');
  ct       text := nullif(trim(coalesce(d ->> 'city', '')), '');
  v_extra  jsonb;
  v_tags   text[];
  src      uuid;
  u        jsonb;
  is_new   boolean;
begin
  select * into f from public.funnels where id = p_funnel;
  if f.id is null then raise exception 'Funnel not found.'; end if;
  if ph is null or length(private.norm_phone(ph)) < 10 then raise exception 'A valid phone number is required.'; end if;

  if full_n is not null then
    fname := split_part(full_n, ' ', 1);
    lname := nullif(trim(substr(full_n, length(fname) + 1)), '');
  else
    fname := nullif(trim(coalesce(d ->> 'first_name', '')), '');
    lname := nullif(trim(coalesce(d ->> 'last_name', '')), '');
  end if;

  -- everything that is not a standard field is kept as an extra field
  v_extra := coalesce((select jsonb_object_agg(k, v) from jsonb_each(d) as e(k, v)
                     where k not in ('name', 'first_name', 'last_name', 'phone', 'email', 'city',
                                     'utm_source', 'utm_medium', 'utm_campaign', 'utm_term', 'utm_content')
                       and coalesce(trim(v #>> '{}'), '') <> ''), '{}');
  u := jsonb_build_object(
    'utm_source', nullif(trim(coalesce(d ->> 'utm_source', '')), ''),
    'utm_medium', nullif(trim(coalesce(d ->> 'utm_medium', '')), ''),
    'utm_campaign', nullif(trim(coalesce(d ->> 'utm_campaign', '')), ''),
    'utm_term', nullif(trim(coalesce(d ->> 'utm_term', '')), ''),
    'utm_content', nullif(trim(coalesce(d ->> 'utm_content', '')), ''));
  v_tags := case when p_add_tags then f.tags else '{}' end;
  select name into pg_name from public.landing_pages where id = p_page;

  select id into lid from public.leads
  where funnel_id = f.id and not is_archived and private.norm_phone(phone) = private.norm_phone(ph)
  order by created_at limit 1;
  is_new := lid is null;

  if is_new then
    if fname is null then raise exception 'Name is required.'; end if;
    select id into st from public.funnel_stages where funnel_id = f.id order by sort_order limit 1;
    -- lead source from utm_source when it matches a source name, else Website / Other
    select id into src from public.lead_sources
    where tenant_id = f.tenant_id and is_active and lower(name) = lower(coalesce(u ->> 'utm_source', ''));
    if src is null then
      select id into src from public.lead_sources
      where tenant_id = f.tenant_id and name = case when p_via = 'webhook' then 'Website' else 'Other' end;
    end if;
    insert into public.leads (tenant_id, business_id, funnel_id, stage_id, first_name, last_name, phone, email, city,
                              source_id, tags, landing_page_id, utm_source, utm_medium, utm_campaign, utm_term, utm_content,
                              extra, created_by)
    values (f.tenant_id, f.business_id, f.id, st, fname, lname, ph, em, ct, src, v_tags, p_page,
            u ->> 'utm_source', u ->> 'utm_medium', u ->> 'utm_campaign', u ->> 'utm_term', u ->> 'utm_content',
            v_extra, p_actor)
    returning id into lid;
    insert into public.lead_activities (tenant_id, lead_id, kind, to_stage_id, note, member_id)
    values (f.tenant_id, lid, case when p_via = 'import' then 'imported' else 'created' end, st,
            case when p_via = 'import' then 'Imported' || coalesce(' (' || pg_name || ')', '')
                 else 'Submitted the form on ' || coalesce(pg_name, 'a landing page') end
            || coalesce(' · utm_source ' || (u ->> 'utm_source'), ''),
            p_actor);
  else
    update public.leads l set
      first_name   = coalesce(fname, l.first_name),
      last_name    = case when fname is not null then lname else l.last_name end,
      email        = coalesce(em, l.email),
      city         = coalesce(ct, l.city),
      extra        = l.extra || v_extra,
      tags         = (select coalesce(array_agg(distinct t), '{}') from unnest(l.tags || v_tags) t),
      landing_page_id = coalesce(p_page, l.landing_page_id),
      utm_source   = coalesce(u ->> 'utm_source', l.utm_source),
      utm_medium   = coalesce(u ->> 'utm_medium', l.utm_medium),
      utm_campaign = coalesce(u ->> 'utm_campaign', l.utm_campaign),
      utm_term     = coalesce(u ->> 'utm_term', l.utm_term),
      utm_content  = coalesce(u ->> 'utm_content', l.utm_content)
    where l.id = lid;
    insert into public.lead_activities (tenant_id, lead_id, kind, note, member_id)
    values (f.tenant_id, lid, case when p_via = 'import' then 'imported' else 'submission' end,
            case when p_via = 'import' then 'Updated by an import' || coalesce(' (' || pg_name || ')', '')
                 else 'Submitted the form again on ' || coalesce(pg_name, 'a landing page') end
            || coalesce(' · utm_source ' || (u ->> 'utm_source'), ''),
            p_actor);
  end if;

  insert into public.lead_submissions (tenant_id, lead_id, funnel_id, landing_page_id, via, is_new,
                                       utm_source, utm_medium, utm_campaign, utm_term, utm_content, data)
  values (f.tenant_id, lid, f.id, p_page, p_via, is_new,
          u ->> 'utm_source', u ->> 'utm_medium', u ->> 'utm_campaign', u ->> 'utm_term', u ->> 'utm_content', d);

  return jsonb_build_object('lead_id', lid, 'status', case when is_new then 'created' else 'updated' end);
end;
$$;

-- Called by the lead-webhook function (service key only).
create or replace function public.webhook_submit(p_key text, p_data jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  p    public.landing_pages;
  d    jsonb := coalesce(p_data, '{}');
  fld  jsonb;
  miss text[] := '{}';
begin
  select * into p from public.landing_pages where webhook_key = p_key and is_active and archived_at is null;
  if p.id is null then raise exception 'Unknown or inactive webhook key.'; end if;

  -- name may come as name or first_name (+ last_name)
  if coalesce(trim(d ->> 'name'), '') = '' and coalesce(trim(d ->> 'first_name'), '') <> '' then
    d := d || jsonb_build_object('name', trim(concat_ws(' ', d ->> 'first_name', d ->> 'last_name')));
  end if;
  if coalesce(trim(d ->> 'phone'), '') = '' then
    d := d || jsonb_build_object('phone', coalesce(d ->> 'contact', d ->> 'mobile', d ->> 'whatsapp', ''));
  end if;

  if coalesce(trim(d ->> 'name'), '') = '' then miss := miss || 'name'; end if;
  if coalesce(trim(d ->> 'email'), '') = '' then miss := miss || 'email'; end if;
  if coalesce(trim(d ->> 'phone'), '') = '' then miss := miss || 'phone'; end if;
  for fld in select * from jsonb_array_elements(p.fields) loop
    if (fld ->> 'required')::boolean and coalesce(trim(d ->> (fld ->> 'key')), '') = '' then
      miss := miss || (fld ->> 'key');
    end if;
  end loop;
  if array_length(miss, 1) > 0 then raise exception 'Missing required field(s): %', array_to_string(miss, ', '); end if;
  if (d ->> 'email') !~ '^[^\s@]+@[^\s@]+\.[^\s@]+$' then raise exception 'Enter a valid email.'; end if;
  if length(private.norm_phone(d ->> 'phone')) < 10 then raise exception 'Enter a valid phone number (10 digits).'; end if;

  -- the page's default UTMs fill in whatever the form did not send
  if coalesce(d ->> 'utm_source', '') = '' and p.utm_source is not null then d := d || jsonb_build_object('utm_source', p.utm_source); end if;
  if coalesce(d ->> 'utm_medium', '') = '' and p.utm_medium is not null then d := d || jsonb_build_object('utm_medium', p.utm_medium); end if;
  if coalesce(d ->> 'utm_campaign', '') = '' and p.utm_campaign is not null then d := d || jsonb_build_object('utm_campaign', p.utm_campaign); end if;

  -- drop helper keys the form may send
  d := d - 'key' - '_redirect' - 'redirect' - 'contact' - 'mobile';
  return private.ingest_lead(p.funnel_id, p.id, d, 'webhook', true, null);
end;
$$;

-- Leads import (Leads page). p_from_funnel = the list came from this funnel → funnel tags are added.
-- p_rows: [{name, phone, email, city, …}]; returns {created, updated, skipped, errors: [{row, error}]}
create or replace function public.import_leads(p_funnel uuid, p_page uuid, p_from_funnel boolean, p_rows jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  f      public.funnels;
  me     uuid;
  r      jsonb;
  i      int := 0;
  res    jsonb;
  c_new  int := 0;
  c_upd  int := 0;
  errs   jsonb := '[]';
begin
  select * into f from public.funnels where id = p_funnel and is_active;
  if f.id is null then raise exception 'Pick a funnel.'; end if;
  if not (private.has_permission(f.tenant_id, 'leads', 'add') and private.can_access_business(f.business_id)) then
    raise exception 'You don’t have permission to import leads here.';
  end if;
  if p_page is not null and not exists (select 1 from public.landing_pages where id = p_page and funnel_id = f.id) then
    raise exception 'That landing page is not part of this funnel.';
  end if;
  if jsonb_array_length(coalesce(p_rows, '[]')) > 5000 then raise exception 'Import up to 5,000 rows at a time.'; end if;
  me := private.my_member_id(f.tenant_id);

  for r in select * from jsonb_array_elements(coalesce(p_rows, '[]')) loop
    i := i + 1;
    begin
      res := private.ingest_lead(f.id, p_page, r, 'import', coalesce(p_from_funnel, false), me);
      if res ->> 'status' = 'created' then c_new := c_new + 1; else c_upd := c_upd + 1; end if;
    exception when others then
      errs := errs || jsonb_build_object('row', i, 'error', sqlerrm);
    end;
  end loop;
  return jsonb_build_object('created', c_new, 'updated', c_upd, 'skipped', jsonb_array_length(errs), 'errors', errs);
end;
$$;

revoke execute on all functions in schema private from public, anon;
grant execute on all functions in schema private to authenticated;
-- only the two entry points below may add leads this way
revoke execute on function private.ingest_lead(uuid, uuid, jsonb, text, boolean, uuid) from authenticated;
revoke execute on function public.webhook_submit(text, jsonb) from public, anon, authenticated;
grant execute on function public.webhook_submit(text, jsonb) to service_role;
revoke execute on function public.import_leads(uuid, uuid, boolean, jsonb) from public, anon;
grant execute on function public.import_leads(uuid, uuid, boolean, jsonb) to authenticated;
