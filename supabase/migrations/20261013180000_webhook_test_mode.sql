-- ============================================================
-- Landing page webhooks: no fixed form fields any more.
--   * test mode: "Listen for a test" saves the next form post as a sample (no lead is made)
--   * field mapping: the sample's fields are matched to lead fields (saved as field_map);
--     anything not mapped is recognised by common names (name / full_name, mobile / contact / phone,
--     email / email_id, company / company_name, purpose / reason, note / notes / remarks…), the rest is
--     kept as an extra field on the lead
--   * name, email and phone are required; "note" goes into the lead's notes
-- ============================================================
alter table public.landing_pages
  add column field_map       jsonb not null default '{}',   -- {"incoming_key": "phone" | "email" | … | "extra" | "ignore"}
  add column test_mode_until timestamptz,
  add column sample          jsonb,
  add column sample_at       timestamptz;

-- incoming form data → standard lead keys (name, first_name, last_name, phone, email, city, company_name, purpose, note, utm_*)
create or replace function private.map_lead_fields(d jsonb, fmap jsonb)
returns jsonb language plpgsql immutable set search_path = '' as $$
declare
  k text;
  v text;
  target text;
  outp jsonb := '{}';
begin
  for k, v in select key, value #>> '{}' from jsonb_each(coalesce(d, '{}')) loop
    if coalesce(trim(v), '') = '' then continue; end if;
    target := coalesce(fmap ->> k, case
      when k in ('name', 'full_name', 'fullname', 'your_name', 'customer_name', 'lead_name') then 'name'
      when k in ('first_name', 'firstname', 'fname', 'given_name') then 'first_name'
      when k in ('last_name', 'lastname', 'lname', 'surname', 'family_name') then 'last_name'
      when k in ('phone', 'contact', 'contact_no', 'contact_number', 'mobile', 'mobileno', 'mobile_no', 'mobile_number',
                 'phone_no', 'phone_number', 'whatsapp', 'whatsapp_no', 'whatsapp_number', 'number') then 'phone'
      when k in ('email', 'email_id', 'emailid', 'email_address', 'mail', 'e_mail') then 'email'
      when k in ('city', 'town', 'location') then 'city'
      when k in ('company', 'company_name', 'business', 'business_name', 'organization', 'organisation', 'firm') then 'company_name'
      when k in ('purpose', 'reason', 'requirement', 'interest', 'interested_in', 'service') then 'purpose'
      when k in ('note', 'notes', 'remark', 'remarks', 'message', 'comment', 'comments', 'query') then 'note'
      when k like 'utm\_%' then k
      else 'extra' end);
    if target = 'ignore' then continue; end if;
    if target = 'extra' then target := k; end if;
    -- first value wins for a field (e.g. both "mobile" and "phone" sent)
    if not (outp ? target) then outp := outp || jsonb_build_object(target, trim(v)); end if;
  end loop;
  return outp;
end;
$$;

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
  nt       text := nullif(trim(coalesce(d ->> 'note', '')), '');
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
                     where k not in ('name', 'first_name', 'last_name', 'phone', 'email', 'city', 'note',
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
                              extra, notes, created_by)
    values (f.tenant_id, f.business_id, f.id, st, fname, lname, ph, em, ct, src, v_tags, p_page,
            u ->> 'utm_source', u ->> 'utm_medium', u ->> 'utm_campaign', u ->> 'utm_term', u ->> 'utm_content',
            v_extra, nt, p_actor)
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
      notes        = case when nt is null then l.notes when l.notes is null then nt
                          when position(nt in l.notes) > 0 then l.notes else l.notes || E'\n' || nt end,
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
  d    jsonb;
  miss text[] := '{}';
begin
  select * into p from public.landing_pages where webhook_key = p_key and is_active and archived_at is null;
  if p.id is null then raise exception 'Unknown or inactive webhook key.'; end if;

  -- test mode: keep the post as a sample for field mapping, make no lead
  if p.test_mode_until is not null and p.test_mode_until > now() then
    update public.landing_pages
    set sample = coalesce(p_data, '{}') - 'key' - '_redirect' - 'redirect', sample_at = now(), test_mode_until = null
    where id = p.id;
    return jsonb_build_object('status', 'test', 'message', 'Test received. Map the fields in the app.');
  end if;

  d := private.map_lead_fields(coalesce(p_data, '{}') - 'key' - '_redirect' - 'redirect', p.field_map);
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

  return private.ingest_lead(null, p.funnel_id, p.id, d, 'webhook', true, null);
end;
$$;
