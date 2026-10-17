-- What the platform owner allows each workspace to connect, set in the admin panel:
--   tenants.connections = { "whatsapp": { "allowed": true, "provider": "wati" | "dovesoft" | "aisensy" | "meta" } }
-- The workspace then enters its own keys in System Connections, for that provider only.

alter table public.tenants add column connections jsonb not null default '{}'::jsonb;

-- a WhatsApp connection is saved only when allowed, and only for the provider the admin picked
create or replace function private.integration_check()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  c jsonb;
begin
  if new.provider = 'whatsapp' then
    select connections -> 'whatsapp' into c from public.tenants where id = new.tenant_id;
    if coalesce((c ->> 'allowed')::boolean, false) is not true then
      raise exception 'WhatsApp isn’t enabled for this workspace. Ask BizDock to turn it on.';
    end if;
    if (new.config ->> 'vendor') is distinct from (c ->> 'provider') then
      raise exception 'This workspace uses % for WhatsApp.', coalesce(c ->> 'provider', 'another provider');
    end if;
  end if;
  return new;
end;
$$;
create trigger integrations_check before insert or update of config, provider on public.integrations
  for each row execute function private.integration_check();
revoke execute on function private.integration_check() from public, anon;

-- demo (Viral): WhatsApp allowed through WATI (applied with execute_sql)
-- update tenants set connections = '{"whatsapp":{"allowed":true,"provider":"wati"}}' where id = '15c9c249-…';

-- (applied as tenant_connections_all) every connection needs the admin's allow, not only WhatsApp:
--   connections = { whatsapp: {allowed, provider}, callyzer: {allowed}, zoom: {allowed}, voice_call: {allowed}, perisclaw: {allowed} }
create or replace function private.integration_check()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  c jsonb;
begin
  select connections -> new.provider into c from public.tenants where id = new.tenant_id;
  if coalesce((c ->> 'allowed')::boolean, false) is not true then
    raise exception 'This connection isn’t enabled for your workspace. Ask BizDock to turn it on.';
  end if;
  if new.provider = 'whatsapp' and (new.config ->> 'vendor') is distinct from (c ->> 'provider') then
    raise exception 'This workspace uses % for WhatsApp.', coalesce(c ->> 'provider', 'another provider');
  end if;
  return new;
end;
$$;
-- demo: Viral allowed everything (execute_sql)
