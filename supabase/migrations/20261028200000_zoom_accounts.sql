-- Zoom: several Zoom accounts per workspace (Server-to-Server OAuth apps). Each meeting / calendar event
-- picks one; the Zoom meeting (or webinar) is created, moved and removed with it. After it ends the
-- attendance, webinar Q&A and in-meeting chat (from the cloud recording) are pulled in.

create table public.zoom_accounts (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenants(id) on delete cascade,
  name            text not null,
  account_id      text not null,
  client_id       text not null,
  client_secret   text not null,
  -- the Zoom user the meetings are created under (email or user id); empty = the app's owner ("me")
  host_email      text,
  -- record to the cloud so the chat can be fetched afterwards
  cloud_record    boolean not null default true,
  is_default      boolean not null default false,
  status          text not null default 'connected' check (status in ('connected', 'error')),
  last_error      text,
  created_by      uuid references public.tenant_members(id) on delete set null,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (tenant_id, name)
);
create unique index zoom_accounts_one_default on public.zoom_accounts (tenant_id) where is_default;
create trigger zoom_accounts_set_updated_at before update on public.zoom_accounts
  for each row execute function public.set_updated_at();

alter table public.zoom_accounts enable row level security;
-- keys: only "Settings & integrations"
create policy "zoom_accounts: read" on public.zoom_accounts for select to authenticated
  using (private.has_permission(tenant_id, 'settings', 'edit'));
create policy "zoom_accounts: write" on public.zoom_accounts for all to authenticated
  using (private.has_permission(tenant_id, 'settings', 'edit'))
  with check (private.has_permission(tenant_id, 'settings', 'edit'));
grant select, insert, update, delete on public.zoom_accounts to authenticated;
revoke all on public.zoom_accounts from anon;

-- Zoom must be allowed for the workspace (admin panel → connections.zoom.allowed)
create or replace function private.zoom_account_check()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if coalesce((select (connections -> 'zoom' ->> 'allowed')::boolean from public.tenants where id = new.tenant_id), false) is not true then
    raise exception 'Zoom isn’t enabled for your workspace. Ask BizDock to turn it on.';
  end if;
  if new.is_default then
    update public.zoom_accounts set is_default = false where tenant_id = new.tenant_id and id <> new.id and is_default;
  end if;
  return new;
end $$;
create trigger zoom_accounts_check before insert or update on public.zoom_accounts
  for each row execute function private.zoom_account_check();

-- names only, for the pickers (anyone in the workspace)
create or replace function public.zoom_account_options(p_tenant uuid)
returns table (id uuid, name text, is_default boolean, status text)
language sql stable security definer set search_path = '' as $$
  select z.id, z.name, z.is_default, z.status from public.zoom_accounts z
  where z.tenant_id = p_tenant and (private.is_member(p_tenant) or private.is_platform_owner())
  order by z.is_default desc, z.name
$$;
grant execute on function public.zoom_account_options(uuid) to authenticated;

-- ---- what each meeting / event keeps ----
alter table public.meetings
  add column if not exists zoom_account_id uuid references public.zoom_accounts(id) on delete set null,
  add column if not exists zoom_meeting_id text,
  add column if not exists zoom_start_url text,
  add column if not exists zoom_password text,
  add column if not exists zoom_error text,
  add column if not exists zoom_pulled_at timestamptz,
  add column if not exists zoom_pull_count int not null default 0;

alter table public.events
  add column if not exists zoom_account_id uuid references public.zoom_accounts(id) on delete set null,
  -- create it in Zoom as a meeting or a webinar (webinar needs the Zoom Webinars add-on)
  add column if not exists zoom_kind text not null default 'meeting' check (zoom_kind in ('meeting', 'webinar')),
  add column if not exists zoom_start_url text,
  add column if not exists zoom_password text,
  add column if not exists zoom_error text,
  add column if not exists zoom_pulled_at timestamptz,
  add column if not exists zoom_pull_count int not null default 0;
-- events.zoom_webinar_id is the Zoom meeting / webinar ID

-- meeting webhooks can create the Zoom meeting too
alter table public.funnel_webhooks add column if not exists zoom_account_id uuid references public.zoom_accounts(id) on delete set null;

-- (webhook_submit below books the meeting on the webhook's Zoom account)

-- ---- attendance and comments pulled from Zoom ----
create table public.zoom_attendance (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenants(id) on delete cascade,
  meeting_id  uuid references public.meetings(id) on delete cascade,
  event_id    uuid references public.events(id) on delete cascade,
  lead_id     uuid references public.leads(id) on delete set null,
  name        text,
  email       text,
  join_time   timestamptz,
  leave_time  timestamptz,
  minutes     int not null default 0,
  sessions    int not null default 1,
  created_at  timestamptz not null default now(),
  check ((meeting_id is null) <> (event_id is null))
);
create index zoom_attendance_meeting on public.zoom_attendance (meeting_id);
create index zoom_attendance_event on public.zoom_attendance (event_id);
create index zoom_attendance_lead on public.zoom_attendance (lead_id);

create table public.zoom_comments (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenants(id) on delete cascade,
  meeting_id  uuid references public.meetings(id) on delete cascade,
  event_id    uuid references public.events(id) on delete cascade,
  lead_id     uuid references public.leads(id) on delete set null,
  kind        text not null check (kind in ('qa', 'chat')),
  name        text,
  email       text,
  body        text not null,
  answer      text,
  said_at     timestamptz,
  created_at  timestamptz not null default now(),
  check ((meeting_id is null) <> (event_id is null))
);
create index zoom_comments_meeting on public.zoom_comments (meeting_id);
create index zoom_comments_event on public.zoom_comments (event_id);
create index zoom_comments_lead on public.zoom_comments (lead_id);

alter table public.zoom_attendance enable row level security;
alter table public.zoom_comments enable row level security;
create policy "zoom_attendance: read" on public.zoom_attendance for select to authenticated
  using (case when meeting_id is not null then private.has_permission(tenant_id, 'meetings', 'view') else private.can_see_event(event_id) end);
create policy "zoom_comments: read" on public.zoom_comments for select to authenticated
  using (case when meeting_id is not null then private.has_permission(tenant_id, 'meetings', 'view') else private.can_see_event(event_id) end);
grant select on public.zoom_attendance, public.zoom_comments to authenticated;
revoke all on public.zoom_attendance, public.zoom_comments from anon;

-- ---- talk to the zoom function ----
create or replace function private.kick_zoom(p_body jsonb)
returns void language sql security definer set search_path = '' as $$
  select net.http_post(
    url := 'https://tnnjudehqalkgglzkfik.supabase.co/functions/v1/zoom',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-secret', public.workflow_cron_secret()),
    body := p_body,
    timeout_milliseconds := 30000
  );
$$;

-- create / move / remove the Zoom meeting with the CRM meeting
create or replace function private.meeting_zoom_sync()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'DELETE' then
    if old.zoom_meeting_id is not null and old.zoom_account_id is not null then
      perform private.kick_zoom(jsonb_build_object('action', 'delete', 'account', old.zoom_account_id, 'zoom_id', old.zoom_meeting_id, 'kind', 'meeting'));
    end if;
    return old;
  end if;
  if tg_op = 'UPDATE' and (new.meeting_date, new.start_time, new.end_time, new.mode, new.status, new.zoom_account_id)
                          is not distinct from (old.meeting_date, old.start_time, old.end_time, old.mode, old.status, old.zoom_account_id)
     and new.zoom_meeting_id is not null then
    return new;  -- nothing Zoom cares about changed
  end if;
  if new.zoom_account_id is not null and new.mode = 'online' and new.status <> 'cancelled' then
    perform private.kick_zoom(jsonb_build_object('action', 'sync', 'kind', 'meeting', 'id', new.id));
  elsif tg_op = 'UPDATE' and old.zoom_meeting_id is not null and old.zoom_account_id is not null
        and (new.status = 'cancelled' or new.mode <> 'online' or new.zoom_account_id is distinct from old.zoom_account_id) then
    perform private.kick_zoom(jsonb_build_object('action', 'delete', 'account', old.zoom_account_id, 'zoom_id', old.zoom_meeting_id, 'kind', 'meeting', 'clear', new.id));
  end if;
  return new;
exception when others then
  return coalesce(new, old);  -- never block saving the meeting
end $$;
create trigger meetings_zoom_ins after insert on public.meetings
  for each row when (new.zoom_account_id is not null) execute function private.meeting_zoom_sync();
create trigger meetings_zoom_upd after update of meeting_date, start_time, end_time, mode, status, zoom_account_id on public.meetings
  for each row execute function private.meeting_zoom_sync();
create trigger meetings_zoom_del after delete on public.meetings
  for each row when (old.zoom_meeting_id is not null) execute function private.meeting_zoom_sync();

create or replace function private.event_zoom_sync()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'DELETE' then
    if old.zoom_webinar_id is not null and old.zoom_account_id is not null then
      perform private.kick_zoom(jsonb_build_object('action', 'delete', 'account', old.zoom_account_id, 'zoom_id', old.zoom_webinar_id, 'kind', old.zoom_kind));
    end if;
    return old;
  end if;
  if tg_op = 'UPDATE' and (new.event_date, new.start_time, new.end_time, new.title, new.topic, new.is_cancelled, new.zoom_account_id, new.zoom_kind)
                          is not distinct from (old.event_date, old.start_time, old.end_time, old.title, old.topic, old.is_cancelled, old.zoom_account_id, old.zoom_kind)
     and new.zoom_webinar_id is not null then
    return new;
  end if;
  if new.zoom_account_id is not null and not new.is_cancelled and new.start_time is not null then
    perform private.kick_zoom(jsonb_build_object('action', 'sync', 'kind', 'event', 'id', new.id));
  elsif tg_op = 'UPDATE' and old.zoom_webinar_id is not null and old.zoom_account_id is not null
        and (new.is_cancelled or new.zoom_account_id is distinct from old.zoom_account_id) then
    perform private.kick_zoom(jsonb_build_object('action', 'delete', 'account', old.zoom_account_id, 'zoom_id', old.zoom_webinar_id, 'kind', old.zoom_kind, 'clear_event', new.id));
  end if;
  return new;
exception when others then
  return coalesce(new, old);
end $$;
create trigger events_zoom_ins after insert on public.events
  for each row when (new.zoom_account_id is not null) execute function private.event_zoom_sync();
create trigger events_zoom_upd after update of event_date, start_time, end_time, title, topic, is_cancelled, zoom_account_id, zoom_kind on public.events
  for each row execute function private.event_zoom_sync();
create trigger events_zoom_del after delete on public.events
  for each row when (old.zoom_webinar_id is not null) execute function private.event_zoom_sync();

-- ---- attendance pulls: 30 min after the end, and again after 4 hours (cloud recording chat is ready by then) ----
create or replace function public.zoom_due(p_limit int default 10)
returns table (kind text, id uuid)
language sql stable security definer set search_path = '' as $$
  (select 'meeting', m.id from public.meetings m
   where m.zoom_meeting_id is not null and m.zoom_account_id is not null and m.status <> 'cancelled'
     and ((m.meeting_date + m.end_time) at time zone 'Asia/Kolkata') > now() - interval '3 days'
     and ((m.zoom_pull_count = 0 and ((m.meeting_date + m.end_time) at time zone 'Asia/Kolkata') < now() - interval '30 minutes')
       or (m.zoom_pull_count = 1 and ((m.meeting_date + m.end_time) at time zone 'Asia/Kolkata') < now() - interval '4 hours'))
   limit p_limit)
  union all
  (select 'event', e.id from public.events e
   where e.zoom_webinar_id is not null and e.zoom_account_id is not null and not e.is_cancelled
     and ((coalesce(e.end_date, e.event_date) + coalesce(e.end_time, e.start_time, time '23:00')) at time zone 'Asia/Kolkata') > now() - interval '3 days'
     and ((e.zoom_pull_count = 0 and ((coalesce(e.end_date, e.event_date) + coalesce(e.end_time, e.start_time, time '23:00')) at time zone 'Asia/Kolkata') < now() - interval '30 minutes')
       or (e.zoom_pull_count = 1 and ((coalesce(e.end_date, e.event_date) + coalesce(e.end_time, e.start_time, time '23:00')) at time zone 'Asia/Kolkata') < now() - interval '4 hours'))
   limit p_limit)
$$;
revoke all on function public.zoom_due(int) from public, anon, authenticated;
grant execute on function public.zoom_due(int) to service_role;

select cron.schedule('zoom-pull', '*/10 * * * *', $job$
  select private.kick_zoom('{"action":"cron"}'::jsonb) where exists (select 1 from public.zoom_due(1));
$job$);

revoke execute on all functions in schema private from public, anon;
grant execute on all functions in schema private to authenticated;

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
  pool  uuid[];
  n     int;
  pos   int;
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
    -- who takes it: a team member the booking tool names (if found in Team), else the webhook's setting
    host := nullif(trim(coalesce(d ->> 'meeting_team_member', '')), '');
    host_id := private.member_by_name(l.tenant_id, host);
    if host_id is null then
      if w.meet_mode = 'owner' then
        host_id := l.owner_id;
      else
        select coalesce(array_agg(m order by ord), '{}') into pool
        from unnest(w.meet_members) with ordinality as x(m, ord)
        where exists (select 1 from public.tenant_members t where t.id = x.m and t.status = 'active');
        n := coalesce(array_length(pool, 1), 0);
        if n > 0 and w.meet_mode = 'single' then
          host_id := pool[1];
        elsif n > 0 then
          update public.funnel_webhooks set meet_cursor = meet_cursor + 1 where id = w.id returning meet_cursor into pos;
          host_id := pool[((pos - 1) % n) + 1];
        end if;
      end if;
    end if;
    insert into public.meetings (tenant_id, business_id, sub_business_id, lead_id, meeting_date, start_time, end_time, mode, link, assigned_to, zoom_account_id)
    values (l.tenant_id, l.business_id, coalesce(l.sub_business_id, f.sub_business_id), l.id,
            (t0 at time zone 'Asia/Kolkata')::date, (t0 at time zone 'Asia/Kolkata')::time,
            case when (t1 at time zone 'Asia/Kolkata')::date > (t0 at time zone 'Asia/Kolkata')::date then time '23:59'
                 else (t1 at time zone 'Asia/Kolkata')::time end,
            'online', nullif(trim(coalesce(d ->> 'meeting_link', '')), ''), host_id, w.zoom_account_id)
    returning id into mid;
    v_note := 'Meeting booked by ' || w.name || ' for ' || to_char(t0 at time zone 'Asia/Kolkata', 'DD Mon YYYY, HH12:MI AM')
              || coalesce(' · with ' || (select p.full_name from public.tenant_members tm join public.profiles p on p.id = tm.user_id where tm.id = host_id), '')
              || case when host is not null and private.member_by_name(l.tenant_id, host) is null then ' (' || host || ' not found in Team)' else '' end;

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
