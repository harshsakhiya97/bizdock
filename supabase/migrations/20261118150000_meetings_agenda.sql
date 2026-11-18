-- Meetings: an optional agenda (lead and team meetings)
alter table public.meetings add column if not exists agenda text;
