-- Per-workspace opt-in menu pages (e.g. '/enrolled-courses') and word changes (e.g. {"Product": "Course"}). Default: none.
alter table public.tenants
  add column if not exists extra_pages text[] not null default '{}',
  add column if not exists labels jsonb not null default '{}'::jsonb;

-- resolve_tenant_v2 is new (21 Nov) and not used by any live build yet; recreate it with the extra columns.
drop function if exists public.resolve_tenant_v2(text, text);
create function public.resolve_tenant_v2(p_domain text default null, p_key text default null)
returns table(id uuid, name text, app_name text, logo_url text, favicon_url text, primary_color text,
              supabase_url text, supabase_key text, app_url text, sidebar_style text, hide_bizdock_branding boolean,
              hidden_pages text[], extra_pages text[], labels jsonb)
language sql stable security definer
set search_path to ''
as $function$
  select t.id, t.name, t.app_name, t.logo_url, t.favicon_url, t.primary_color, t.supabase_url, t.supabase_key,
         (select rtrim('https://' || d.domain || '/' || trim(both '/' from d.base_path), '/')
            from public.tenant_domains d where d.tenant_id = t.id
           order by d.is_primary desc, d.created_at limit 1) as app_url,
         t.sidebar_style, t.hide_bizdock_branding, t.hidden_pages, t.extra_pages, t.labels
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
