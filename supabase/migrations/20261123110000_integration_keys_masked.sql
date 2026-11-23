-- System Connections: saved keys / secrets / tokens reach the browser masked (AB••••••••YZ); the full key only through
-- Copy (edge function integration-key, after the person's password). Part 1: the masked list and the save guard.
-- (Part 2, 20261123110100, takes away the browser's read of the raw config once the new app is live.)

-- the config values that are keys / secrets / tokens (same list as the integration-key function)
create or replace function private.integration_secret_keys()
returns text[] language sql immutable set search_path = '' as $$
  select array['api_key','access_token','key_secret','client_secret','developer_token','refresh_token','api_token','webhook_secret']
$$;

-- AB••••••••YZ (short values: only dots)
create or replace function private.mask_secret(v text)
returns text language sql immutable set search_path = '' as $$
  select case when v is null or v = '' then v
              when length(v) <= 8 then repeat('•', 8)
              else left(v, 2) || repeat('•', 8) || right(v, 2) end
$$;

create or replace function private.mask_config(c jsonb)
returns jsonb language sql immutable set search_path = '' as $$
  select coalesce(jsonb_object_agg(e.key,
           case when e.key = any (private.integration_secret_keys()) and jsonb_typeof(e.value) = 'string'
                then to_jsonb(private.mask_secret(e.value #>> '{}')) else e.value end), '{}'::jsonb)
  from jsonb_each(coalesce(c, '{}'::jsonb)) e
$$;

-- System Connections list: every connection of the workspace, keys masked (the Meta token from meta_tokens, masked too)
create or replace function public.integrations_list(p_tenant uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', i.id, 'tenant_id', i.tenant_id, 'provider', i.provider, 'is_enabled', i.is_enabled,
           'config', private.mask_config(
                       case when i.provider = 'facebook_ads' and not (i.config ? 'access_token') and t.access_token is not null
                            then coalesce(i.config, '{}'::jsonb) || jsonb_build_object('access_token', t.access_token)
                            else i.config end),
           'label', i.label, 'status', i.status, 'last_error', i.last_error, 'connected_by', i.connected_by,
           'connected_at', i.connected_at, 'updated_at', i.updated_at) order by i.connected_at), '[]'::jsonb)
  from public.integrations i
  left join public.meta_tokens t on t.integration_id = i.id
  where i.tenant_id = p_tenant and private.has_permission(p_tenant, 'settings', 'edit')
$$;
revoke all on function public.integrations_list(uuid) from public, anon;
grant execute on function public.integrations_list(uuid) to authenticated;

-- a save from the app sends the masked value back for a key it didn't change: keep the saved key
create or replace function private.integrations_keep_keys()
returns trigger language plpgsql set search_path = '' as $$
declare k text;
begin
  foreach k in array private.integration_secret_keys() loop
    if new.config ? k and coalesce(new.config ->> k, '') like '%••%' then
      if tg_op = 'UPDATE' and old.config ? k then
        new.config := jsonb_set(new.config, array[k], old.config -> k);
      else
        new.config := new.config - k;
      end if;
    end if;
  end loop;
  return new;
end $$;

drop trigger if exists integrations_keep_keys on public.integrations;
create trigger integrations_keep_keys before insert or update of config on public.integrations
  for each row execute function private.integrations_keep_keys();
