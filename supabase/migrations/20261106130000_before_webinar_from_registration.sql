-- Before a webinar starts: a lead's run starts as soon as they're registered for a date (until it starts); the
-- reminders' own times are on its Bulk WhatsApp step. After a webinar ends: still this long after the end.
create or replace function private.start_webinar_workflows() returns void
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.workflow_runs (tenant_id, workflow_id, lead_id, event_id)
  select w.tenant_id, w.id, r.lead_id, e.id
    from public.workflows w
    cross join lateral (
      select coalesce(nullif(n.value -> 'data' ->> 'amount', '')::numeric, 0)
             * case n.value -> 'data' ->> 'unit' when 'days' then 1440 when 'hours' then 60 else 1 end as mins
        from jsonb_array_elements(w.nodes) n where n.value ->> 'id' = 'trigger' limit 1) t
    join public.events e on e.webinar_id = w.webinar_id and not e.is_cancelled
    join public.webinar_registrations r on r.event_id = e.id
   where w.is_active and w.archived_at is null and w.webinar_id is not null
     and w.trigger_type in ('before_event', 'after_event')
     and case when w.trigger_type = 'before_event' then
            ((e.event_date + e.start_time) at time zone 'Asia/Kolkata') > now()
          else
            ((e.event_date + coalesce(e.end_time, e.start_time)) at time zone 'Asia/Kolkata') + make_interval(mins => t.mins::int) <= now()
            and ((e.event_date + coalesce(e.end_time, e.start_time)) at time zone 'Asia/Kolkata') + make_interval(mins => t.mins::int) > now() - interval '1 day'
          end
  on conflict (workflow_id, lead_id, event_id) where event_id is not null and not is_test do nothing;
end $$;
