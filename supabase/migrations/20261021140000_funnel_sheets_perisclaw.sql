-- Perisclaw setup per sheet: the example lead message and which part of it goes to which sheet column
alter table public.funnel_sheets add column perisclaw jsonb;
