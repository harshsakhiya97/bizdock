-- Who owns a lead that comes in through a funnel: nobody (default), one person, or round robin over a list
alter table public.funnels add column if not exists assign_mode text not null default 'none'
  check (assign_mode in ('none', 'single', 'round_robin'));
alter table public.funnels add column if not exists assign_members uuid[] not null default '{}';
alter table public.funnels add column if not exists assign_cursor integer not null default 0;

create or replace function private.assign_funnel_owner()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare
  f record;
  pool uuid[];
  n int;
  pos int;
begin
  if new.owner_id is not null or new.funnel_id is null then return new; end if;
  select assign_mode, assign_members into f from public.funnels where id = new.funnel_id;
  if f.assign_mode is null or f.assign_mode = 'none' then return new; end if;
  -- only people still active in the workspace
  select coalesce(array_agg(m order by ord), '{}') into pool
  from unnest(f.assign_members) with ordinality as u(m, ord)
  where exists (select 1 from public.tenant_members t where t.id = u.m and t.status = 'active');
  n := coalesce(array_length(pool, 1), 0);
  if n = 0 then return new; end if;
  if f.assign_mode = 'single' then
    new.owner_id := pool[1];
  else
    -- next person in turn (the counter moves on even with several leads at once)
    update public.funnels set assign_cursor = assign_cursor + 1 where id = new.funnel_id returning assign_cursor into pos;
    new.owner_id := pool[((pos - 1) % n) + 1];
  end if;
  return new;
end $$;

drop trigger if exists leads_assign_funnel_owner on public.leads;
create trigger leads_assign_funnel_owner before insert on public.leads
  for each row execute function private.assign_funnel_owner();
