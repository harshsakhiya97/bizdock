-- Booking Calendar: the visitor's own extra fields (config.fields: key, label, type, required, options) are shown in
-- the embed (widget_public gives them) and kept on the booking (widget_bookings.answers; also posted to the workflow)
alter table public.widget_bookings add column if not exists answers jsonb;

create or replace function public.widget_public(p_code text)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'name', w.name,
    'kind', w.kind,
    'color', w.config -> 'color',
    'interval', w.config -> 'interval',
    'days', w.config -> 'days',
    'days_ahead', w.config -> 'days_ahead',
    'fields', coalesce(w.config -> 'fields', '[]'::jsonb),
    'team', coalesce(array_length(private.widget_members(w), 1), 0)
  )
  from public.widgets w
  where w.code = p_code and w.is_active and w.archived_at is null
$$;
