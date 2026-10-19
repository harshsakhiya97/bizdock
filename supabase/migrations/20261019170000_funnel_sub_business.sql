-- A funnel can belong to a sub-business; leads added through it get that sub-business
-- (form webhook, import, quick add) unless one is given.
alter table public.funnels add column sub_business_id uuid;
alter table public.funnels add constraint funnels_sub_business_fk foreign key (sub_business_id, business_id)
  references public.sub_businesses (id, business_id) on delete set null (sub_business_id);
create index funnels_sub_business_idx on public.funnels (sub_business_id);

create or replace function private.lead_sub_from_funnel()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.sub_business_id is null and new.funnel_id is not null then
    select f.sub_business_id into new.sub_business_id
    from public.funnels f
    where f.id = new.funnel_id and f.business_id = new.business_id;
  end if;
  return new;
end;
$$;
revoke all on function private.lead_sub_from_funnel() from public, anon;

create trigger leads_sub_from_funnel before insert on public.leads
  for each row execute function private.lead_sub_from_funnel();
