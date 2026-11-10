-- A webinar's WhatsApp groups (made on the phone and added to the community): one per date, and a fixed link
-- <app>/<wa_slug> that opens the group of the current date (on now, else the next one).
alter table public.webinars add column if not exists wa_slug text;

create table if not exists public.webinar_groups (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenants(id) on delete cascade,
  webinar_id  uuid not null references public.webinars(id) on delete cascade,
  group_date  date not null,
  name        text,
  invite_link text not null check (invite_link ~* '^https://chat\.whatsapp\.com/[A-Za-z0-9]+'),
  created_at  timestamptz not null default now(),
  unique (webinar_id, group_date)
);
alter table public.webinar_groups enable row level security;
create policy "webinar_groups: read" on public.webinar_groups for select
  using (exists (select 1 from public.webinars w where w.id = webinar_id));
create policy "webinar_groups: write" on public.webinar_groups for all
  using (exists (select 1 from public.webinars w where w.id = webinar_id)
         and (private.has_permission(tenant_id, 'bookings', 'edit') or private.has_permission(tenant_id, 'bookings', 'add')))
  with check (exists (select 1 from public.webinars w where w.id = webinar_id and w.tenant_id = webinar_groups.tenant_id)
         and (private.has_permission(tenant_id, 'bookings', 'edit') or private.has_permission(tenant_id, 'bookings', 'add')));

-- the join link and the group link share one name space per workspace
create or replace function private.webinars_slug() returns trigger language plpgsql set search_path = '' as $$
declare
  base text;
  cand text;
  n int := 1;
  taken boolean;
begin
  if new.archived_at is not null then return new; end if;
  -- the join link
  new.slug := nullif(private.webinar_slugify(new.slug), '');
  if not (new.slug is not null and tg_op = 'UPDATE' and new.slug is not distinct from old.slug) then
    base := coalesce(new.slug, nullif(private.webinar_slugify(new.title), ''), 'webinar');
    if length(base) < 3 or private.webinar_slug_reserved(base) then base := left(base || '-webinar', 60); end if;
    if new.slug is not null then
      if exists (select 1 from public.webinars w where w.tenant_id = new.tenant_id and w.id <> new.id and w.archived_at is null and (w.slug = base or w.wa_slug = base)) then
        raise exception 'The link “%” is already used by another webinar.', base using errcode = '23505';
      end if;
      new.slug := base;
    else
      cand := base;
      loop
        taken := exists (select 1 from public.webinars w where w.tenant_id = new.tenant_id and w.id <> new.id and w.archived_at is null and (w.slug = cand or w.wa_slug = cand));
        exit when not taken;
        n := n + 1;
        cand := left(base, 55) || '-' || n;
      end loop;
      new.slug := cand;
    end if;
  end if;
  -- the WhatsApp group link (empty: <join link>-wa)
  new.wa_slug := nullif(private.webinar_slugify(new.wa_slug), '');
  if not (new.wa_slug is not null and tg_op = 'UPDATE' and new.wa_slug is not distinct from old.wa_slug) then
    base := coalesce(new.wa_slug, left(new.slug, 57) || '-wa');
    if length(base) < 3 or private.webinar_slug_reserved(base) then base := left(base || '-wa', 60); end if;
    if base = new.slug then raise exception 'The WhatsApp group link must differ from the join link.' using errcode = '23505'; end if;
    if new.wa_slug is not null then
      if exists (select 1 from public.webinars w where w.tenant_id = new.tenant_id and w.id <> new.id and w.archived_at is null and (w.slug = base or w.wa_slug = base)) then
        raise exception 'The link “%” is already used by another webinar.', base using errcode = '23505';
      end if;
      new.wa_slug := base;
    else
      cand := base;
      n := 1;
      loop
        taken := cand = new.slug or exists (select 1 from public.webinars w where w.tenant_id = new.tenant_id and w.id <> new.id and w.archived_at is null and (w.slug = cand or w.wa_slug = cand));
        exit when not taken;
        n := n + 1;
        cand := left(base, 55) || '-' || n;
      end loop;
      new.wa_slug := cand;
    end if;
  end if;
  return new;
end $$;
drop trigger if exists webinars_slug on public.webinars;
create trigger webinars_slug before insert or update of slug, wa_slug, title on public.webinars
  for each row execute function private.webinars_slug();

-- the webinars there are now get their group link
update public.webinars set wa_slug = null where archived_at is null and wa_slug is null;
create unique index if not exists webinars_wa_slug_live on public.webinars (tenant_id, wa_slug) where archived_at is null;

/**
 * <app>/<link>: a webinar's join link → the Zoom link of its current date (on now, else the next one);
 * its WhatsApp group link → that date's WhatsApp group. Null when there's none (yet).
 */
create or replace function public.webinar_link_open(p_tenant uuid, p_slug text)
returns text language plpgsql stable security definer set search_path = '' as $$
declare
  w public.webinars;
  ev public.events;
  v text;
begin
  select * into w from public.webinars
   where tenant_id = p_tenant and archived_at is null and (slug = lower(p_slug) or wa_slug = lower(p_slug)) limit 1;
  if w.id is null then return null; end if;
  select * into ev from public.events e
   where e.webinar_id = w.id and not e.is_cancelled
     and ((e.event_date + coalesce(e.end_time, e.start_time)) at time zone 'Asia/Kolkata') > now()
   order by e.event_date, e.start_time limit 1;
  if w.slug = lower(p_slug) then return ev.meeting_link; end if;
  -- the group of the current date, else (no date made yet) the next group from today
  select g.invite_link into v from public.webinar_groups g
   where g.webinar_id = w.id
     and (case when ev.id is not null then g.group_date = ev.event_date
               else g.group_date >= (now() at time zone 'Asia/Kolkata')::date end)
   order by g.group_date limit 1;
  return v;
end $$;
revoke all on function public.webinar_link_open(uuid, text) from public;
grant execute on function public.webinar_link_open(uuid, text) to anon, authenticated;
