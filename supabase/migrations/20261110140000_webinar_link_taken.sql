/** while typing a webinar's join / WhatsApp group link: is it taken (another live webinar of the workspace, or an app page)? */
create or replace function public.webinar_link_taken(p_tenant uuid, p_slug text, p_except uuid default null)
returns boolean language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.is_member(p_tenant) then return null; end if;
  return private.webinar_slug_reserved(lower(p_slug))
      or exists (select 1 from public.webinars w
                  where w.tenant_id = p_tenant and w.archived_at is null
                    and (p_except is null or w.id <> p_except)
                    and (w.slug = lower(p_slug) or w.wa_slug = lower(p_slug)));
end $$;
revoke all on function public.webinar_link_taken(uuid, text, uuid) from public;
grant execute on function public.webinar_link_taken(uuid, text, uuid) to authenticated;
