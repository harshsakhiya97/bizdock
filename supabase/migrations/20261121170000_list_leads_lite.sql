-- Lighter version of list_leads for the lists (same rows and the same access rule): each lead's `extra` keeps only the
-- fields the lists read (form submitted time, Paid Podcast steps, Studio purpose / time / describes), and empty (null)
-- fields are left out (the app fills them back in as null). A 22,000-lead import went from ~35 MB to ~14 MB.
create or replace function public.list_leads_lite(p_tenant uuid, p_offset integer default 0, p_limit integer default 1000)
returns setof jsonb
language sql stable security invoker
set search_path to ''
as $function$
  select jsonb_strip_nulls(to_jsonb(l) - 'extra') || jsonb_build_object('extra', coalesce((
           select jsonb_object_agg(e.key, e.value) from jsonb_each(l.extra) e
            where regexp_replace(lower(trim(e.key)), '[^a-z0-9]+', '_', 'g') in
              ('submitted', 'submitted_at', 'submitted_at_utc', 'submitted_on', 'timestamp', 'vsl_form_at', 'call_booked_at', 'purpose', 'time', 'describes')
         ), '{}'::jsonb))
  from public.list_leads(p_tenant, p_offset, p_limit) l
$function$;
revoke all on function public.list_leads_lite(uuid, integer, integer) from public;
grant execute on function public.list_leads_lite(uuid, integer, integer) to authenticated;
