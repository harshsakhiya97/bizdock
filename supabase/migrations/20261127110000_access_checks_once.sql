-- Speed: the access checks behind every read rule (leads, follow-ups, calls, WhatsApp, meetings, submissions, …)
-- worked out each time — for every row — the person's role, scope, team and businesses. Now each answer is worked out
-- once per request and kept for the rest of it (a transaction-local setting, keyed by the person and the inputs).
-- The rules are unchanged; a team member counting their leads went from ~10 s to milliseconds.
-- Also: the call-transcribe job (every minute) finds its work by index.

-- the key also carries a generation that goes up when roles / members / their businesses change in this request
create or replace function private.memo_k(p text) returns text
language sql stable set search_path = '' as $$ select 'bz.m' || md5(p || '|' || coalesce(nullif(current_setting('bz.gen', true), ''), '0')) $$;

create or replace function private.memo_bump() returns trigger
language plpgsql set search_path = '' as $$
begin
  perform set_config('bz.gen', (coalesce(nullif(current_setting('bz.gen', true), ''), '0')::int + 1)::text, true);
  return null;
end $$;
drop trigger if exists memo_bump on public.tenant_members;
create trigger memo_bump after insert or update or delete on public.tenant_members for each statement execute function private.memo_bump();
drop trigger if exists memo_bump on public.member_businesses;
create trigger memo_bump after insert or update or delete on public.member_businesses for each statement execute function private.memo_bump();
drop trigger if exists memo_bump on public.roles;
create trigger memo_bump after insert or update or delete on public.roles for each statement execute function private.memo_bump();
drop trigger if exists memo_bump on public.platform_owners;
create trigger memo_bump after insert or update or delete on public.platform_owners for each statement execute function private.memo_bump();

create or replace function private.is_platform_owner() returns boolean
language plpgsql stable security definer set search_path = '' as $$
declare
  k text := private.memo_k('po|' || coalesce((select auth.uid())::text, '-'));
  v text := current_setting(k, true);
  r boolean;
begin
  if v in ('1', '0') then return v = '1'; end if;
  r := exists (select 1 from public.platform_owners where user_id = (select auth.uid()));
  perform set_config(k, case when r then '1' else '0' end, true);
  return r;
end $$;

create or replace function private.is_member(t uuid) returns boolean
language plpgsql stable security definer set search_path = '' as $$
declare
  k text := private.memo_k('im|' || coalesce((select auth.uid())::text, '-') || '|' || coalesce(t::text, '-'));
  v text := current_setting(k, true);
  r boolean;
begin
  if v in ('1', '0') then return v = '1'; end if;
  r := exists (select 1 from public.tenant_members where tenant_id = t and user_id = (select auth.uid()) and status = 'active');
  perform set_config(k, case when r then '1' else '0' end, true);
  return r;
end $$;

create or replace function private.my_member_id(t uuid) returns uuid
language plpgsql stable security definer set search_path = '' as $$
declare
  k text := private.memo_k('mm|' || coalesce((select auth.uid())::text, '-') || '|' || coalesce(t::text, '-'));
  v text := current_setting(k, true);
  r uuid;
begin
  if v is not null and v <> '' then return nullif(v, '-')::uuid; end if;
  select id into r from public.tenant_members where tenant_id = t and user_id = (select auth.uid()) and status = 'active';
  perform set_config(k, coalesce(r::text, '-'), true);
  return r;
end $$;

create or replace function private.has_permission(t uuid, module text, action text) returns boolean
language plpgsql stable security definer set search_path = '' as $$
declare
  k text := private.memo_k('hp|' || coalesce((select auth.uid())::text, '-') || '|' || coalesce(t::text, '-') || '|' || coalesce(module, '') || '|' || coalesce(action, ''));
  v text := current_setting(k, true);
  r boolean;
begin
  if v in ('1', '0') then return v = '1'; end if;
  r := private.is_platform_owner() or exists (
    select 1
    from public.tenant_members m
    join public.roles ro on ro.id = m.role_id
    cross join lateral (select coalesce(m.permissions, ro.permissions) as p) x
    where m.tenant_id = t and m.user_id = (select auth.uid()) and m.status = 'active'
      and (
        ro.is_system or ro.level <= 1
        or (
          coalesce((x.p -> module ->> action)::boolean, false)
          and not (action <> 'view' and coalesce((x.p -> 'mode' ->> 'view_only')::boolean, false))
        )
        or (module = 'funnels' and action = 'view' and coalesce((x.p -> 'funnel_report' ->> 'view')::boolean, false))
      )
  );
  perform set_config(k, case when r then '1' else '0' end, true);
  return r;
end $$;

create or replace function private.area_scope(t uuid, area text) returns text
language plpgsql stable security definer set search_path = '' as $$
declare
  k text := private.memo_k('as|' || coalesce((select auth.uid())::text, '-') || '|' || coalesce(t::text, '-') || '|' || coalesce(area, ''));
  v text := current_setting(k, true);
  r text;
begin
  if v is not null and v <> '' then return nullif(v, '~'); end if;
  r := case
    when private.is_platform_owner() then 'all'
    else (
      select case
        when ro.is_system or ro.level <= 1 then 'all'
        else coalesce(coalesce(m.permissions, ro.permissions) -> 'scope' ->> area, 'none')
      end
      from public.tenant_members m join public.roles ro on ro.id = m.role_id
      where m.tenant_id = t and m.user_id = (select auth.uid()) and m.status = 'active'
    )
  end;
  perform set_config(k, coalesce(r, '~'), true);
  return r;
end $$;

create or replace function private.lead_scope(t uuid) returns text
language plpgsql stable security definer set search_path = '' as $$
declare
  k text := private.memo_k('ls|' || coalesce((select auth.uid())::text, '-') || '|' || coalesce(t::text, '-'));
  v text := current_setting(k, true);
  r text;
begin
  if v is not null and v <> '' then return nullif(v, '~'); end if;
  r := case
    when private.is_platform_owner() then 'all'
    else (
      select case
        when ro.is_system or ro.level <= 1 then 'all'
        else coalesce(coalesce(m.permissions, ro.permissions) -> 'scope' ->> 'leads', 'none')
      end
      from public.tenant_members m join public.roles ro on ro.id = m.role_id
      where m.tenant_id = t and m.user_id = (select auth.uid()) and m.status = 'active'
    )
  end;
  perform set_config(k, coalesce(r, '~'), true);
  return r;
end $$;

create or replace function private.can_access_business(b uuid) returns boolean
language plpgsql stable security definer set search_path = '' as $$
declare
  k text := private.memo_k('cb|' || coalesce((select auth.uid())::text, '-') || '|' || coalesce(b::text, '-'));
  v text := current_setting(k, true);
  r boolean;
begin
  if v in ('1', '0') then return v = '1'; end if;
  r := private.is_platform_owner() or exists (
    select 1
    from public.businesses bz
    join public.tenant_members m on m.tenant_id = bz.tenant_id
    where bz.id = b and m.user_id = (select auth.uid()) and m.status = 'active'
      and (m.all_businesses
           or exists (select 1 from public.member_businesses mb where mb.member_id = m.id and mb.business_id = b))
  );
  perform set_config(k, case when r then '1' else '0' end, true);
  return r;
end $$;

create or replace function private.can_access_sub(b uuid, s uuid) returns boolean
language plpgsql stable security definer set search_path = '' as $$
declare
  k text;
  v text;
  r boolean;
begin
  if s is null then return true; end if;
  k := private.memo_k('cs|' || coalesce((select auth.uid())::text, '-') || '|' || coalesce(b::text, '-') || '|' || s::text);
  v := current_setting(k, true);
  if v in ('1', '0') then return v = '1'; end if;
  r := private.is_platform_owner() or exists (
    select 1
    from public.businesses bz
    join public.tenant_members m on m.tenant_id = bz.tenant_id
    where bz.id = b and m.user_id = (select auth.uid()) and m.status = 'active'
      and (m.all_businesses
           or exists (select 1 from public.member_businesses mb
                      where mb.member_id = m.id and mb.business_id = b
                        and (coalesce(cardinality(mb.sub_business_ids), 0) = 0 or s = any (mb.sub_business_ids))))
  );
  perform set_config(k, case when r then '1' else '0' end, true);
  return r;
end $$;

-- the person and everyone who reports to them (any depth), once per request
create or replace function private.my_team_ids(t uuid) returns uuid[]
language plpgsql stable security definer set search_path = '' as $$
declare
  k text := private.memo_k('mt|' || coalesce((select auth.uid())::text, '-') || '|' || coalesce(t::text, '-'));
  v text := current_setting(k, true);
  r uuid[];
begin
  if v is not null and v <> '' then return v::uuid[]; end if;
  with recursive tree as (
    select id from public.tenant_members where tenant_id = t and user_id = (select auth.uid())
    union
    select m.id from public.tenant_members m join tree on m.reports_to = tree.id
  )
  select coalesce(array_agg(id), '{}') into r from tree;
  perform set_config(k, r::text, true);
  return r;
end $$;

create or replace function private.my_team(t uuid) returns setof uuid
language sql stable security definer set search_path = '' as $$
  select unnest(private.my_team_ids(t))
$$;

create or replace function private.can_see_lead(t uuid, b uuid, owner uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select private.can_access_business(b) and case private.lead_scope(t)
    when 'all'  then true
    when 'team' then owner is null or owner = any (private.my_team_ids(t))
    when 'own'  then owner = private.my_member_id(t)
    else false
  end
$$;

-- the every-minute call-transcribe job: its "anything to do?" check by index
create index if not exists calls_transcribe_todo on public.calls (started_at)
  where source = 'callyzer' and recording_path is not null and (transcript_status is null or transcript_status = 'waiting');
