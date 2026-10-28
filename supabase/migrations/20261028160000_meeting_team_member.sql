-- Meeting webhooks: the team member who takes the meeting (matched by name) is saved on it.
alter table public.meetings add column if not exists assigned_to uuid references public.tenant_members(id) on delete set null;

-- an active team member by full name (or a first name only one member has)
create or replace function private.member_by_name(p_tenant uuid, p_name text)
returns uuid language sql stable security definer set search_path = '' as $$
  select coalesce(
    (select m.id from public.tenant_members m join public.profiles p on p.id = m.user_id
      where m.tenant_id = p_tenant and m.status = 'active' and lower(trim(p.full_name)) = lower(trim(p_name)) limit 1),
    (select min(m.id::text)::uuid from public.tenant_members m join public.profiles p on p.id = m.user_id
      where m.tenant_id = p_tenant and m.status = 'active' and lower(split_part(trim(p.full_name), ' ', 1)) = lower(split_part(trim(p_name), ' ', 1))
      having count(*) = 1))
  where coalesce(trim(p_name), '') <> ''
$$;

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
  host  text;
  host_id uuid;
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
    -- the team member who takes it, by the name the booking tool sends
    host := nullif(trim(coalesce(d ->> 'meeting_team_member', '')), '');
    host_id := private.member_by_name(l.tenant_id, host);
    insert into public.meetings (tenant_id, business_id, sub_business_id, lead_id, meeting_date, start_time, end_time, mode, link, assigned_to)
    values (l.tenant_id, l.business_id, coalesce(l.sub_business_id, f.sub_business_id), l.id,
            (t0 at time zone 'Asia/Kolkata')::date, (t0 at time zone 'Asia/Kolkata')::time,
            case when (t1 at time zone 'Asia/Kolkata')::date > (t0 at time zone 'Asia/Kolkata')::date then time '23:59'
                 else (t1 at time zone 'Asia/Kolkata')::time end,
            'online', nullif(trim(coalesce(d ->> 'meeting_link', '')), ''), host_id)
    returning id into mid;
    v_note := 'Meeting booked by ' || w.name || ' for ' || to_char(t0 at time zone 'Asia/Kolkata', 'DD Mon YYYY, HH12:MI AM')
              || case when host is null then '' when host_id is null then ' · with ' || host || ' (not found in Team)' else ' · with ' || host end;

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
