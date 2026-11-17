-- Callyzer → Team numbers → a staff number's calls (with the lead, when the number is a lead's)
create or replace function public.callyzer_team_calls_of(p_tenant uuid, p_emp text, p_from timestamptz, p_to timestamptz)
returns table (external_id text, started_at timestamptz, client_number text, call_type text, call_method text, call_mode text,
               duration_sec int, recording_url text, lead_id uuid, lead_name text)
language sql stable security definer set search_path to '' as $$
  select c.external_id, c.started_at, c.client_number, c.call_type, c.call_method, c.call_mode, c.duration_sec, c.recording_url,
         l.id, nullif(trim(concat_ws(' ', l.first_name, l.last_name)), '')
    from public.callyzer_team_calls c
    left join lateral (
      select x.id, x.first_name, x.last_name from public.leads x
       where x.tenant_id = p_tenant and c.client_number is not null
         and right(regexp_replace(coalesce(x.phone, ''), '\D', '', 'g'), 10) = c.client_number
       order by x.created_at desc limit 1) l on true
   where c.tenant_id = p_tenant and c.emp_number = p_emp and c.started_at >= p_from and c.started_at < p_to
     and (private.has_permission(p_tenant, 'call_logs', 'view') or private.has_permission(p_tenant, 'settings', 'edit'))
   order by c.started_at desc
$$;
revoke all on function public.callyzer_team_calls_of(uuid, text, timestamptz, timestamptz) from public, anon;
grant execute on function public.callyzer_team_calls_of(uuid, text, timestamptz, timestamptz) to authenticated;
