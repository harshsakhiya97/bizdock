-- ============================================================
-- Leads without a funnel: an import can answer "add them to a funnel?" = No.
-- Such a lead belongs to a business only (no funnel, no stage) until someone puts it in a funnel.
-- ============================================================
alter table public.leads alter column funnel_id drop not null, alter column stage_id drop not null;
alter table public.lead_submissions alter column funnel_id drop not null;

create or replace function private.check_lead_stage()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.funnel_id is null then
    if new.stage_id is not null then raise exception 'A lead without a funnel has no stage'; end if;
  elsif new.stage_id is null
     or not exists (select 1 from public.funnel_stages s where s.id = new.stage_id and s.funnel_id = new.funnel_id) then
    raise exception 'That stage is not part of this funnel';
  end if;
  if tg_op = 'UPDATE' and new.stage_id is distinct from old.stage_id then
    new.stage_changed_at := now();
  end if;
  return new;
end;
$$;

-- The old ingest_lead(6 args) / import_leads(4 args) stay in the database (dropping needs a manual confirm);
-- nobody can call them any more (see the grants migration).

create or replace function private.ingest_lead(
  p_business uuid, p_funnel uuid, p_page uuid, d jsonb, p_via text, p_add_tags boolean, p_actor uuid)
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
  -- no funnel: the lead only belongs to the business (an import with "add to a funnel?" = No)
  if p_funnel is not null then
    select * into f from public.funnels where id = p_funnel;
    if f.id is null then raise exception 'Funnel not found.'; end if;
  else
    select b.id as business_id, b.tenant_id, '{}'::text[] as tags into f.business_id, f.tenant_id, f.tags
    from public.businesses b where b.id = p_business;
    if f.business_id is null then raise exception 'Business not found.'; end if;
  end if;
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

  -- same phone: in this funnel, or (no funnel) anywhere in the business
  select id into lid from public.leads
  where not is_archived and private.norm_phone(phone) = private.norm_phone(ph)
    and case when f.id is not null then funnel_id = f.id else business_id = f.business_id end
  order by (funnel_id is null) desc, created_at limit 1;
  is_new := lid is null;

  if is_new then
    if fname is null then raise exception 'Name is required.'; end if;
    if f.id is not null then
      select id into st from public.funnel_stages where funnel_id = f.id order by sort_order limit 1;
    end if;
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
  return private.ingest_lead(null, p.funnel_id, p.id, d, 'webhook', true, null);
end;
$$;


-- Leads import. p_funnel null = no funnel (p_business required); p_from_funnel = the list came from the funnel → its tags are added.
create or replace function public.import_leads(p_business uuid, p_funnel uuid, p_page uuid, p_from_funnel boolean, p_rows jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  t      uuid;
  b      uuid;
  me     uuid;
  r      jsonb;
  i      int := 0;
  res    jsonb;
  c_new  int := 0;
  c_upd  int := 0;
  errs   jsonb := '[]';
begin
  if p_funnel is not null then
    select tenant_id, business_id into t, b from public.funnels where id = p_funnel and is_active;
    if t is null then raise exception 'Pick a funnel.'; end if;
  else
    select tenant_id, id into t, b from public.businesses where id = p_business and is_active;
    if t is null then raise exception 'Pick a business.'; end if;
  end if;
  if not (private.has_permission(t, 'leads', 'add') and private.can_access_business(b)) then
    raise exception 'You don’t have permission to import leads here.';
  end if;
  if p_page is not null and not exists (select 1 from public.landing_pages where id = p_page and funnel_id = p_funnel) then
    raise exception 'That landing page is not part of this funnel.';
  end if;
  if jsonb_array_length(coalesce(p_rows, '[]')) > 5000 then raise exception 'Import up to 5,000 rows at a time.'; end if;
  me := private.my_member_id(t);

  for r in select * from jsonb_array_elements(coalesce(p_rows, '[]')) loop
    i := i + 1;
    begin
      res := private.ingest_lead(b, p_funnel, p_page, r, 'import', coalesce(p_from_funnel, false) and p_funnel is not null, me);
      if res ->> 'status' = 'created' then c_new := c_new + 1; else c_upd := c_upd + 1; end if;
    exception when others then
      errs := errs || jsonb_build_object('row', i, 'error', sqlerrm);
    end;
  end loop;
  return jsonb_build_object('created', c_new, 'updated', c_upd, 'skipped', jsonb_array_length(errs), 'errors', errs);
end;
$$;
