-- The address a workspace's app lives at: its primary domain + the folder it runs under (e.g. https://pride.viralsakhiya.com/pride).
-- Workflow links (Generate link, Zoom short link) are made on it, also when the builder is used on localhost.
alter table public.tenant_domains add column if not exists base_path text not null default '/';
update public.tenant_domains set base_path = '/pride/' where domain = 'pride.viralsakhiya.com' and base_path = '/';

drop function if exists public.resolve_tenant(text, text);
create function public.resolve_tenant(p_domain text default null, p_key text default null)
returns table (id uuid, name text, app_name text, logo_url text, favicon_url text, primary_color text, supabase_url text, supabase_key text, app_url text)
language sql stable security definer set search_path = ''
as $$
  select t.id, t.name, t.app_name, t.logo_url, t.favicon_url, t.primary_color, t.supabase_url, t.supabase_key,
         (select rtrim('https://' || d.domain || '/' || trim(both '/' from d.base_path), '/')
            from public.tenant_domains d where d.tenant_id = t.id
           order by d.is_primary desc, d.created_at limit 1) as app_url
  from public.tenants t
  where t.status = 'active'
    and (
      (p_key is not null and t.tenant_key = p_key)
      or (p_domain is not null and exists (
            select 1 from public.tenant_domains d where d.tenant_id = t.id and d.domain = lower(p_domain)))
    )
  limit 1
$$;
grant execute on function public.resolve_tenant(text, text) to anon, authenticated, service_role;

-- workflow steps saved from localhost: their links go to the workspace's address instead
update public.workflows w
   set nodes = (
     select jsonb_agg(case when n->'data'->>'base_url' like 'http://localhost%'
                           then jsonb_set(n, '{data,base_url}', to_jsonb(u.app_url)) else n end order by i)
       from jsonb_array_elements(w.nodes) with ordinality as e(n, i))
  from (select d.tenant_id, rtrim('https://' || d.domain || '/' || trim(both '/' from d.base_path), '/') app_url
          from public.tenant_domains d where d.is_primary) u
 where u.tenant_id = w.tenant_id
   and exists (select 1 from jsonb_array_elements(w.nodes) n where n->'data'->>'base_url' like 'http://localhost%');
