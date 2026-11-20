-- Masters → Podcast Studios: the studios Paid Podcast and Studio Rental bookings take place in (name + one default).
-- Every studio booking has a studio (the default when none is picked); "Studio not available" is per studio, across
-- the workspace's studio businesses. Existing studio bookings go to the default studio "Podcast Studio - Vakola".

create table if not exists public.podcast_studios (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  name text not null check (length(btrim(name)) between 1 and 120),
  is_default boolean not null default false,
  sort_order integer not null default 0,
  created_at timestamptz not null default now()
);
create index if not exists podcast_studios_tenant on public.podcast_studios (tenant_id);
create unique index if not exists podcast_studios_one_default on public.podcast_studios (tenant_id) where is_default;
alter table public.podcast_studios enable row level security;
drop policy if exists "podcast_studios: read" on public.podcast_studios;
create policy "podcast_studios: read" on public.podcast_studios for select
  using (private.is_member(tenant_id) or private.is_platform_owner());
drop policy if exists "podcast_studios: insert" on public.podcast_studios;
create policy "podcast_studios: insert" on public.podcast_studios for insert
  with check (private.has_permission(tenant_id, 'masters', 'edit'));
drop policy if exists "podcast_studios: update" on public.podcast_studios;
create policy "podcast_studios: update" on public.podcast_studios for update
  using (private.has_permission(tenant_id, 'masters', 'edit')) with check (private.has_permission(tenant_id, 'masters', 'edit'));
drop policy if exists "podcast_studios: delete" on public.podcast_studios;
create policy "podcast_studios: delete" on public.podcast_studios for delete
  using (private.has_permission(tenant_id, 'masters', 'edit'));
grant select, insert, update, delete on public.podcast_studios to authenticated;

-- one default per workspace: ticking one unticks the others
create or replace function private.podcast_studio_default() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.is_default then
    update public.podcast_studios set is_default = false where tenant_id = new.tenant_id and id <> new.id and is_default;
  end if;
  return new;
end $$;
drop trigger if exists podcast_studios_default on public.podcast_studios;
create trigger podcast_studios_default before insert or update of is_default on public.podcast_studios
  for each row execute function private.podcast_studio_default();

-- a booking's studio (a studio with bookings can't be deleted)
alter table public.bookings add column if not exists studio_id uuid references public.podcast_studios(id) on delete restrict;
create index if not exists bookings_studio on public.bookings (studio_id);

-- the default studio for every workspace with a studio business, and its studio bookings
insert into public.podcast_studios (tenant_id, name, is_default, sort_order)
select distinct b.tenant_id, 'Podcast Studio - Vakola', true, 1
  from public.businesses b
 where private.is_studio_biz(b.id, null)
   and not exists (select 1 from public.podcast_studios s where s.tenant_id = b.tenant_id);

alter table public.bookings disable trigger user;
update public.bookings k set studio_id = s.id
  from public.podcast_studios s
 where s.tenant_id = k.tenant_id and s.is_default and k.studio_id is null and private.is_studio_biz(k.business_id, k.sub_business_id);
alter table public.bookings enable trigger user;

-- the studio check, per studio
create or replace function private.booking_before_save() returns trigger
language plpgsql security definer set search_path = '' as $function$
declare c record;
begin
  new.gst_amount := case when new.gst_applicable then round(new.amount * new.gst_rate / 100, 2) else 0 end;
  new.total_amount := new.amount + new.gst_amount;

  if private.is_studio_biz(new.business_id, new.sub_business_id) then
    -- a studio booking always has a studio: the default one when none is picked
    if new.studio_id is null then
      select id into new.studio_id from public.podcast_studios where tenant_id = new.tenant_id order by is_default desc, sort_order, created_at limit 1;
    end if;
  else
    new.studio_id := null;
  end if;

  if new.status <> 'cancelled' and private.is_studio_biz(new.business_id, new.sub_business_id) then
    select b.client_name, b.start_time, b.end_time, coalesce(s.name, bz.name) as sub_name, ps.name as studio into c
      from public.bookings b
      left join public.sub_businesses s on s.id = b.sub_business_id
      join public.businesses bz on bz.id = b.business_id
      left join public.podcast_studios ps on ps.id = b.studio_id
     where b.tenant_id = new.tenant_id and b.booking_date = new.booking_date and b.status <> 'cancelled'
       and b.id <> new.id and private.is_studio_biz(b.business_id, b.sub_business_id)
       and b.studio_id is not distinct from new.studio_id
       and b.start_time < new.end_time and b.end_time > new.start_time
     order by b.start_time limit 1;
    if found then
      raise exception '% not available on % from % to %: booked for % (%).',
        coalesce(c.studio, 'Studio'), to_char(new.booking_date, 'DD Mon YYYY'), to_char(c.start_time, 'HH12:MI AM'), to_char(c.end_time, 'HH12:MI AM'),
        c.client_name, coalesce(c.sub_name, 'another booking');
    end if;
  elsif new.status = 'confirmed' and new.start_time < new.end_time and not private.is_default_biz(new.business_id, new.sub_business_id) and exists (
    select 1 from public.bookings b
    where b.business_id = new.business_id and b.booking_date = new.booking_date and b.status = 'confirmed'
      and b.id <> new.id and b.start_time < new.end_time and b.end_time > new.start_time
      and not private.is_studio_biz(b.business_id, b.sub_business_id)
  ) then
    raise exception 'This slot overlaps another confirmed booking on %.', to_char(new.booking_date, 'DD Mon YYYY');
  end if;
  return new;
end $function$;

-- the studios' bookings, with their studio
drop function if exists public.studio_busy(uuid, date, date);
create function public.studio_busy(p_business uuid, p_from date default null, p_to date default null)
returns table(id uuid, sub_business_id uuid, sub_name text, client_name text, purpose text, booking_date date, start_time time, end_time time, status text,
              studio_id uuid, studio_name text)
language sql stable security definer set search_path = '' as $$
  select b.id, coalesce(b.sub_business_id, b.business_id), coalesce(s.name, bz.name), b.client_name, b.purpose, b.booking_date, b.start_time, b.end_time, b.status,
         b.studio_id, ps.name
    from public.bookings b
    join public.businesses me on me.id = p_business
    join public.businesses bz on bz.id = b.business_id
    left join public.sub_businesses s on s.id = b.sub_business_id
    left join public.podcast_studios ps on ps.id = b.studio_id
   where b.tenant_id = me.tenant_id and private.can_access_business(p_business)
     and private.is_studio_biz(b.business_id, b.sub_business_id) and b.status <> 'cancelled'
     and (p_from is null or b.booking_date >= p_from) and (p_to is null or b.booking_date <= p_to)
$$;
revoke all on function public.studio_busy(uuid, date, date) from public, anon;
grant execute on function public.studio_busy(uuid, date, date) to authenticated;
