-- Per-workspace sidebar look: 'light' (default, unchanged for every workspace) or 'dark'.
alter table public.tenants
  add column if not exists sidebar_style text not null default 'light'
  check (sidebar_style in ('light', 'dark'));

-- New version of resolve_tenant that also returns sidebar_style. resolve_tenant itself is left as is,
-- so app builds already live keep working.
create or replace function public.resolve_tenant_v2(p_domain text default null, p_key text default null)
returns table(id uuid, name text, app_name text, logo_url text, favicon_url text, primary_color text,
              supabase_url text, supabase_key text, app_url text, sidebar_style text)
language sql stable security definer
set search_path to ''
as $function$
  select t.id, t.name, t.app_name, t.logo_url, t.favicon_url, t.primary_color, t.supabase_url, t.supabase_key,
         (select rtrim('https://' || d.domain || '/' || trim(both '/' from d.base_path), '/')
            from public.tenant_domains d where d.tenant_id = t.id
           order by d.is_primary desc, d.created_at limit 1) as app_url,
         t.sidebar_style
  from public.tenants t
  where t.status = 'active'
    and (
      (p_key is not null and t.tenant_key = p_key)
      or (p_domain is not null and exists (
            select 1 from public.tenant_domains d where d.tenant_id = t.id and d.domain = lower(p_domain)))
    )
  limit 1
$function$;

grant execute on function public.resolve_tenant_v2(text, text) to anon, authenticated, service_role;
