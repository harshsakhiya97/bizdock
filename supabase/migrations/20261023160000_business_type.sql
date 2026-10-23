-- A business either has sub-businesses (each with its own type) or a type of its own
alter table public.businesses add column if not exists has_sub_businesses boolean not null default false;
alter table public.businesses add column if not exists type text;
update public.businesses b set has_sub_businesses = true
where exists (select 1 from public.sub_businesses s where s.business_id = b.id and s.is_active);
