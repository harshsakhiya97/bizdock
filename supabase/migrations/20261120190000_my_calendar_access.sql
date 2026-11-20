-- The side menu follows Access control only (not the business picked in the top bar):
--   My Calendar (calendar.view) · Studio Schedule (bookings.*) · Bookings (booking_list.view) · Orders (orders.view)
--   webinars (Schedule → Webinar in My Calendar): webinars.edit
-- Nobody loses anything: everyone gets My Calendar (everyone saw Meetings), whoever had the bookings menu gets Bookings
-- and Orders, and whoever could add / edit bookings can add / edit webinars.
-- A webinar's host is a team member now (Masters → Webinar hosts goes away; the table stays).

-- ---------- permissions ----------
create or replace function private.flat_menu_perms(p jsonb) returns jsonb
language sql immutable as $$
  select case when p is null then null else
    p || jsonb_build_object(
      'calendar', coalesce(p -> 'calendar', '{}'::jsonb) || '{"view": true}'::jsonb,
      'booking_list', coalesce(p -> 'booking_list', '{}'::jsonb) || jsonb_build_object('view', coalesce((p #>> '{bookings,view}')::boolean, false)),
      'orders', coalesce(p -> 'orders', '{}'::jsonb) || jsonb_build_object('view', coalesce((p #>> '{bookings,view}')::boolean, false)),
      'webinars', coalesce(p -> 'webinars', '{}'::jsonb) || jsonb_build_object('edit', coalesce((p #>> '{bookings,add}')::boolean, false) or coalesce((p #>> '{bookings,edit}')::boolean, false))
    ) end
$$;
update public.roles set permissions = private.flat_menu_perms(permissions) where permissions is not null and not (permissions ? 'calendar');
update public.tenant_members set permissions = private.flat_menu_perms(permissions) where permissions is not null and not (permissions ? 'calendar');
drop function private.flat_menu_perms(jsonb);

-- ---------- webinars: edit permission ----------
drop policy if exists "webinars: insert" on public.webinars;
create policy "webinars: insert" on public.webinars for insert
  with check (private.has_permission(tenant_id, 'webinars', 'edit') and private.can_access_business(business_id));
drop policy if exists "webinars: update" on public.webinars;
create policy "webinars: update" on public.webinars for update
  using (private.has_permission(tenant_id, 'webinars', 'edit') and private.can_access_business(business_id))
  with check (private.can_access_business(business_id));
drop policy if exists "webinar_groups: write" on public.webinar_groups;
create policy "webinar_groups: write" on public.webinar_groups for all
  using (exists (select 1 from public.webinars w where w.id = webinar_groups.webinar_id) and private.has_permission(tenant_id, 'webinars', 'edit'))
  with check (exists (select 1 from public.webinars w where w.id = webinar_groups.webinar_id and w.tenant_id = webinar_groups.tenant_id)
              and private.has_permission(tenant_id, 'webinars', 'edit'));

-- webinar_reschedule / webinar_delete_date: the same check, on webinars.edit
do $$
declare f text; d text;
begin
  foreach f in array array['public.webinar_reschedule(uuid, date, date, time, time, text, jsonb, uuid)', 'public.webinar_delete_date(uuid, boolean, jsonb, uuid)'] loop
    d := pg_get_functiondef(f::regprocedure);
    d := replace(d, '(private.has_permission(w.tenant_id, ''bookings'', ''edit'') or private.has_permission(w.tenant_id, ''bookings'', ''add''))',
                    'private.has_permission(w.tenant_id, ''webinars'', ''edit'')');
    d := replace(d, '(private.has_permission(ev.tenant_id, ''bookings'', ''edit'') or private.has_permission(ev.tenant_id, ''bookings'', ''add''))',
                    'private.has_permission(ev.tenant_id, ''webinars'', ''edit'')');
    if d not like '%''webinars'', ''edit''%' then raise exception 'permission check not found in %', f; end if;
    execute d;
  end loop;
end $$;

-- ---------- a webinar's host: a team member ----------
alter table public.webinars add column if not exists host_member_id uuid references public.tenant_members(id) on delete set null;
create index if not exists webinars_host_member on public.webinars (host_member_id);

-- new workspaces: every preset role opens My Calendar
do $$
declare d text;
begin
  d := pg_get_functiondef('private.preset(text)'::regprocedure);
  d := replace(d, '"calendar": {"add":true}', '"calendar": {"add":true,"view":true}');
  d := replace(d, '"tasks": {"view":true},
      "funnels": {"view":true}', '"tasks": {"view":true},
      "calendar": {"view":true},
      "funnels": {"view":true}');
  d := replace(d, '"customers": {"edit":true},
      "tasks": {"view":true}
    }''::jsonb
    else', '"customers": {"edit":true},
      "tasks": {"view":true},
      "calendar": {"view":true}
    }''::jsonb
    else');
  execute d;
end $$;
