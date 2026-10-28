-- Zoom accounts live in System Connections (integrations, provider 'zoom', several per workspace — like
-- Facebook ad accounts) instead of a table of their own. config: account_id, client_id, client_secret,
-- host_email, cloud_record ('Yes' / 'No'), is_default ('Yes' / 'No'); label = the account's name.
drop table if exists public.zoom_accounts cascade;   -- nothing saved in it yet; drops the old foreign keys
drop function if exists private.zoom_account_check();

drop index if exists public.integrations_one_per_provider;
create unique index integrations_one_per_provider on public.integrations (tenant_id, provider)
  where provider not in ('facebook_ads', 'zoom');
create unique index if not exists integrations_zoom_name on public.integrations (tenant_id, lower(label)) where provider = 'zoom';

alter table public.meetings add constraint meetings_zoom_account_fk foreign key (zoom_account_id) references public.integrations(id) on delete set null;
alter table public.events add constraint events_zoom_account_fk foreign key (zoom_account_id) references public.integrations(id) on delete set null;
alter table public.funnel_webhooks add constraint funnel_webhooks_zoom_account_fk foreign key (zoom_account_id) references public.integrations(id) on delete set null;

-- only one default Zoom account
create or replace function private.zoom_one_default()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.provider = 'zoom' and new.config ->> 'is_default' = 'Yes' then
    update public.integrations set config = config || '{"is_default":"No"}'
    where tenant_id = new.tenant_id and provider = 'zoom' and id <> new.id and config ->> 'is_default' = 'Yes';
  end if;
  return new;
end $$;
create trigger integrations_zoom_default after insert or update of config on public.integrations
  for each row when (new.provider = 'zoom') execute function private.zoom_one_default();

-- names only, for the pickers (anyone in the workspace); switched-off accounts are left out
drop function if exists public.zoom_account_options(uuid);
create function public.zoom_account_options(p_tenant uuid)
returns table (id uuid, name text, is_default boolean, status text)
language sql stable security definer set search_path = '' as $$
  select i.id, coalesce(nullif(i.label, ''), 'Zoom'), coalesce(i.config ->> 'is_default', 'No') = 'Yes', i.status
  from public.integrations i
  where i.tenant_id = p_tenant and i.provider = 'zoom' and i.is_enabled
    and (private.is_member(p_tenant) or private.is_platform_owner())
  order by 3 desc, i.connected_at
$$;
grant execute on function public.zoom_account_options(uuid) to authenticated;

revoke execute on all functions in schema private from public, anon;
grant execute on all functions in schema private to authenticated;
