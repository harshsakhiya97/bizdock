-- A form field can be saved as the lead's tags: an array (["LinkedIn", "Podcast"]) arrives as
-- "LinkedIn, Podcast" and, mapped to Tags, adds each value as a tag (new leads, updates, update webhooks).

create or replace function private.tag_list(v text)
returns text[] language sql immutable set search_path = '' as $$
  select coalesce(array_agg(distinct t), '{}') from (
    select trim(x) as t from unnest(string_to_array(coalesce(v, ''), ',')) x) s
  where t <> ''
$$;

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
      when k in ('tags', 'tag', 'labels') then 'tags'
      when k like 'utm\_%' then k
      else 'extra' end);
    if target = 'ignore' then continue; end if;
    if target = 'extra' then target := k;
    elsif target like 'extra:%' then target := coalesce(nullif(trim(substr(target, 7)), ''), k);
    end if;
    if target = 'tags' and outp ? 'tags' then
      -- several fields can add tags
      outp := outp || jsonb_build_object('tags', (outp ->> 'tags') || ', ' || trim(v));
    elsif not (outp ? target) then
      outp := outp || jsonb_build_object(target, trim(v));
    end if;
  end loop;
  return outp;
end $$;


CREATE OR REPLACE FUNCTION private.ingest_lead(p_business uuid, p_funnel uuid, p_page uuid, p_webhook uuid, d jsonb, p_via text, p_add_tags boolean, p_actor uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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

  v_extra := coalesce((select jsonb_object_agg(k, v) from jsonb_each(d) as e(k, v)
                     where k not in ('name', 'first_name', 'last_name', 'phone', 'email', 'city', 'note', 'tags',
                                     'utm_source', 'utm_medium', 'utm_campaign', 'utm_term', 'utm_content')
                       and coalesce(trim(v #>> '{}'), '') <> ''), '{}');
  u := jsonb_build_object(
    'utm_source', nullif(trim(coalesce(d ->> 'utm_source', '')), ''),
    'utm_medium', nullif(trim(coalesce(d ->> 'utm_medium', '')), ''),
    'utm_campaign', nullif(trim(coalesce(d ->> 'utm_campaign', '')), ''),
    'utm_term', nullif(trim(coalesce(d ->> 'utm_term', '')), ''),
    'utm_content', nullif(trim(coalesce(d ->> 'utm_content', '')), ''));
  -- the funnel's tags, plus a form field mapped to Tags (several values: "LinkedIn, Podcast")
  v_tags := case when p_add_tags then f.tags else '{}' end || private.tag_list(d ->> 'tags');
  select coalesce((select w.name from public.funnel_webhooks w where w.id = p_webhook), (select lp.name from public.landing_pages lp where lp.id = p_page)) into pg_name;

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
    select id into src from public.lead_sources
    where tenant_id = f.tenant_id and is_active and lower(name) = lower(coalesce(u ->> 'utm_source', ''));
    if src is null then
      select id into src from public.lead_sources
      where tenant_id = f.tenant_id and name = case when p_via = 'webhook' then 'Website' when p_via = 'sheet' then 'WhatsApp' else 'Other' end;
    end if;
    insert into public.leads (tenant_id, business_id, funnel_id, stage_id, first_name, last_name, phone, email, city,
                              source_id, tags, landing_page_id, webhook_id, utm_source, utm_medium, utm_campaign, utm_term, utm_content,
                              extra, notes, created_by)
    values (f.tenant_id, f.business_id, f.id, st, fname, lname, ph, em, ct, src,
            (select coalesce(array_agg(distinct t), '{}') from unnest(v_tags) t), p_page, p_webhook,
            u ->> 'utm_source', u ->> 'utm_medium', u ->> 'utm_campaign', u ->> 'utm_term', u ->> 'utm_content',
            v_extra, nt, p_actor)
    returning id into lid;
    insert into public.lead_activities (tenant_id, lead_id, kind, to_stage_id, note, member_id)
    values (f.tenant_id, lid, case when p_via = 'import' then 'imported' else 'created' end, st,
            case when p_via = 'sheet' then 'Added from the Google Sheet' || coalesce(' (' || pg_name || ')', '') when p_via = 'import' then 'Imported' || coalesce(' (' || pg_name || ')', '')
                 else 'Submitted the form on ' || coalesce(pg_name, 'a form') end
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
      webhook_id = coalesce(p_webhook, l.webhook_id),
      utm_source   = coalesce(u ->> 'utm_source', l.utm_source),
      utm_medium   = coalesce(u ->> 'utm_medium', l.utm_medium),
      utm_campaign = coalesce(u ->> 'utm_campaign', l.utm_campaign),
      utm_term     = coalesce(u ->> 'utm_term', l.utm_term),
      utm_content  = coalesce(u ->> 'utm_content', l.utm_content)
    where l.id = lid;
    insert into public.lead_activities (tenant_id, lead_id, kind, note, member_id)
    values (f.tenant_id, lid, case when p_via = 'import' then 'imported' else 'submission' end,
            case when p_via = 'sheet' then 'Updated from the Google Sheet' || coalesce(' (' || pg_name || ')', '') when p_via = 'import' then 'Updated by an import' || coalesce(' (' || pg_name || ')', '')
                 else 'Submitted the form again on ' || coalesce(pg_name, 'a form') end
            || coalesce(' · utm_source ' || (u ->> 'utm_source'), ''),
            p_actor);
  end if;

  insert into public.lead_submissions (tenant_id, lead_id, funnel_id, landing_page_id, webhook_id, via, is_new,
                                       utm_source, utm_medium, utm_campaign, utm_term, utm_content, data)
  values (f.tenant_id, lid, f.id, p_page, p_webhook, p_via, is_new,
          u ->> 'utm_source', u ->> 'utm_medium', u ->> 'utm_campaign', u ->> 'utm_term', u ->> 'utm_content', d);

  return jsonb_build_object('lead_id', lid, 'status', case when is_new then 'created' else 'updated' end);
end;
$function$;


create or replace function public.webhook_submit(p_key text, p_data jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  w     public.funnel_webhooks;
  f     public.funnels;
  d     jsonb;
  miss  text[] := '{}';
  ph    text;
  em    text;
  l     public.leads;
  v_extra jsonb;
  u     jsonb;
  t0    timestamptz;
  t1    timestamptz;
  mins  numeric;
  mid   uuid;
  sid   uuid;
  v_note text;
  amt   text;
begin
  select wh.* into w from public.funnel_webhooks wh
  join public.funnels fu on fu.id = wh.funnel_id and fu.is_active
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

  -- 1. new lead (as before)
  if w.action = 'create_lead' then
    if coalesce(d ->> 'name', '') = '' then miss := array_append(miss, 'name'); end if;
    if coalesce(d ->> 'email', '') = '' then miss := array_append(miss, 'email'); end if;
    if coalesce(d ->> 'phone', '') = '' then miss := array_append(miss, 'phone'); end if;
    if array_length(miss, 1) > 0 then raise exception 'Missing required field(s): %', array_to_string(miss, ', '); end if;
    if (d ->> 'email') !~ '^[^\s@]+@[^\s@]+\.[^\s@]+$' then raise exception 'Enter a valid email.'; end if;
    if length(private.norm_phone(d ->> 'phone')) < 10 then raise exception 'Enter a valid phone number (10 digits).'; end if;
    return private.ingest_lead(null, w.funnel_id, null, w.id, d, 'webhook', true, null);
  end if;

  -- 2-4. an existing lead of the funnel's business, found by phone / email
  select * into f from public.funnels where id = w.funnel_id;
  ph := nullif(private.norm_phone(coalesce(d ->> 'phone', '')), '');
  em := nullif(lower(trim(coalesce(d ->> 'email', ''))), '');
  if w.match_by = 'phone' and ph is null then raise exception 'Missing required field: phone'; end if;
  if w.match_by = 'email' and em is null then raise exception 'Missing required field: email'; end if;
  if w.match_by = 'both' and ph is null and em is null then raise exception 'Missing required field: phone or email'; end if;

  if w.match_by in ('phone', 'both') and length(coalesce(ph, '')) >= 10 then
    select * into l from public.leads x
    where x.business_id = f.business_id and not x.is_archived and private.norm_phone(x.phone) = ph
    order by (x.funnel_id = f.id) desc nulls last, x.created_at desc limit 1;
  end if;
  if l.id is null and w.match_by in ('email', 'both') and em is not null then
    select * into l from public.leads x
    where x.business_id = f.business_id and not x.is_archived and lower(x.email) = em
    order by (x.funnel_id = f.id) desc nulls last, x.created_at desc limit 1;
  end if;

  u := jsonb_build_object(
    'utm_source', nullif(trim(coalesce(d ->> 'utm_source', '')), ''),
    'utm_medium', nullif(trim(coalesce(d ->> 'utm_medium', '')), ''),
    'utm_campaign', nullif(trim(coalesce(d ->> 'utm_campaign', '')), ''),
    'utm_term', nullif(trim(coalesce(d ->> 'utm_term', '')), ''),
    'utm_content', nullif(trim(coalesce(d ->> 'utm_content', '')), ''));

  if l.id is null then
    insert into public.lead_submissions (tenant_id, lead_id, funnel_id, webhook_id, via, is_new, action, result,
                                         utm_source, utm_medium, utm_campaign, utm_term, utm_content, data)
    values (w.tenant_id, null, w.funnel_id, w.id, 'webhook', false, w.action, 'no_match',
            u ->> 'utm_source', u ->> 'utm_medium', u ->> 'utm_campaign', u ->> 'utm_term', u ->> 'utm_content', d);
    return jsonb_build_object('status', 'no_match', 'message', 'No lead with this phone / email; the post is logged.');
  end if;

  if w.action = 'update_lead' then
    v_extra := coalesce((select jsonb_object_agg(k, v) from jsonb_each(d) as e(k, v)
                         where k not in ('name', 'phone', 'email', 'city', 'note', 'tags',
                                         'utm_source', 'utm_medium', 'utm_campaign', 'utm_term', 'utm_content')
                           and coalesce(trim(v #>> '{}'), '') <> ''), '{}');
    v_note := nullif(trim(coalesce(d ->> 'note', '')), '');
    update public.leads x set
      first_name = coalesce(nullif(split_part(trim(coalesce(d ->> 'name', '')), ' ', 1), ''), x.first_name),
      last_name  = case when coalesce(trim(d ->> 'name'), '') <> '' then nullif(trim(substr(trim(d ->> 'name'), length(split_part(trim(d ->> 'name'), ' ', 1)) + 1)), '') else x.last_name end,
      email      = coalesce(em, x.email),
      city       = coalesce(nullif(trim(coalesce(d ->> 'city', '')), ''), x.city),
      extra      = x.extra || v_extra,
      tags       = (select coalesce(array_agg(distinct t), '{}') from unnest(x.tags || private.tag_list(d ->> 'tags')) t),
      notes      = case when v_note is null then x.notes when x.notes is null then v_note
                        when position(v_note in x.notes) > 0 then x.notes else x.notes || E'\n' || v_note end,
      utm_source   = coalesce(u ->> 'utm_source', x.utm_source),
      utm_medium   = coalesce(u ->> 'utm_medium', x.utm_medium),
      utm_campaign = coalesce(u ->> 'utm_campaign', x.utm_campaign),
      utm_term     = coalesce(u ->> 'utm_term', x.utm_term),
      utm_content  = coalesce(u ->> 'utm_content', x.utm_content)
    where x.id = l.id;
    v_note := 'Details updated by ' || w.name;

  elsif w.action = 'create_meeting' then
    t0 := private.parse_when(d ->> 'meeting_start');
    if t0 is null then raise exception 'Missing or unreadable meeting_start (date and time of the meeting).'; end if;
    t1 := private.parse_when(d ->> 'meeting_end');
    mins := nullif(regexp_replace(coalesce(d ->> 'meeting_duration', ''), '[^0-9.]', '', 'g'), '')::numeric;
    if t1 is null or t1 <= t0 then t1 := t0 + make_interval(mins => coalesce(nullif(mins, 0), 30)::int); end if;
    -- the meeting is kept in India time, within one day
    insert into public.meetings (tenant_id, business_id, sub_business_id, lead_id, meeting_date, start_time, end_time, mode, link)
    values (l.tenant_id, l.business_id, coalesce(l.sub_business_id, f.sub_business_id), l.id,
            (t0 at time zone 'Asia/Kolkata')::date, (t0 at time zone 'Asia/Kolkata')::time,
            case when (t1 at time zone 'Asia/Kolkata')::date > (t0 at time zone 'Asia/Kolkata')::date then time '23:59'
                 else (t1 at time zone 'Asia/Kolkata')::time end,
            'online', nullif(trim(coalesce(d ->> 'meeting_link', '')), ''))
    returning id into mid;
    v_note := 'Meeting booked by ' || w.name || ' for ' || to_char(t0 at time zone 'Asia/Kolkata', 'DD Mon YYYY, HH12:MI AM');

  else -- purchase: logged only for now
    amt := nullif(trim(coalesce(d ->> 'amount', '')), '');
    v_note := 'Payment received via ' || w.name
            || coalesce(' · ₹' || amt, '')
            || coalesce(' · ' || nullif(trim(coalesce(d ->> 'product', '')), ''), '')
            || coalesce(' · ' || nullif(trim(coalesce(d ->> 'payment_id', '')), ''), '');
  end if;

  insert into public.lead_activities (tenant_id, lead_id, kind, note) values (l.tenant_id, l.id, 'submission', v_note);
  insert into public.lead_submissions (tenant_id, lead_id, funnel_id, webhook_id, via, is_new, action, result,
                                       utm_source, utm_medium, utm_campaign, utm_term, utm_content, data)
  values (w.tenant_id, l.id, w.funnel_id, w.id, 'webhook', false, w.action,
          case w.action when 'update_lead' then 'updated' when 'create_meeting' then 'meeting' else 'payment' end,
          u ->> 'utm_source', u ->> 'utm_medium', u ->> 'utm_campaign', u ->> 'utm_term', u ->> 'utm_content', d)
  returning id into sid;

  return jsonb_build_object('status', case w.action when 'update_lead' then 'updated' when 'create_meeting' then 'meeting' else 'payment' end,
                            'lead_id', l.id, 'meeting_id', mid);
end $$;
