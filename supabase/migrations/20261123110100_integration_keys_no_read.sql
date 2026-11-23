-- System Connections, part 2: the browser can no longer read a connection's raw config (keys). The app lists them with
-- integrations_list (masked); edge functions read keys with the service role. Every other column stays readable.
revoke select on public.integrations from authenticated, anon;
grant select (id, tenant_id, provider, is_enabled, status, last_error, connected_by, connected_at, updated_at, label)
  on public.integrations to authenticated;
