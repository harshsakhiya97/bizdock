-- Access Control → Reports → Funnel Report (funnel_report: view): the report reads what Funnels → view reads (the
-- funnel report RPCs, Facebook / Google ads data, funnel workflows / payments), so funnel_report view counts as
-- funnels view for reading. The Funnels pages in the side menu still need Funnels → view (checked in the app).
create or replace function private.has_permission(t uuid, module text, action text)
returns boolean language sql stable security definer set search_path to '' as $$
  select private.is_platform_owner() or exists (
    select 1
    from public.tenant_members m
    join public.roles r on r.id = m.role_id
    cross join lateral (select coalesce(m.permissions, r.permissions) as p) x
    where m.tenant_id = t and m.user_id = (select auth.uid()) and m.status = 'active'
      and (
        r.is_system or r.level <= 1
        or (
          coalesce((x.p -> module ->> action)::boolean, false)
          and not (action <> 'view' and coalesce((x.p -> 'mode' ->> 'view_only')::boolean, false))
        )
        or (module = 'funnels' and action = 'view' and coalesce((x.p -> 'funnel_report' ->> 'view')::boolean, false))
      )
  )
$$;
