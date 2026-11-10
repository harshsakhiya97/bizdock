-- A webinar's common join link: <app>/<slug> (e.g. https://pride.viralsakhiya.com/pride/ai-income-mastery) opens the Zoom
-- meeting of its current date: the one on now, else the next coming one — so it moves to each new date by itself.
alter table public.webinars add column if not exists slug text;

-- app pages that a slug can't take (they'd open the page instead)
create or replace function private.webinar_slug_reserved(p text) returns boolean language sql immutable as $$
  select p = any (array['login','embed','bookings','my-day','dashboard','businesses','leads','customers','invoices','follow-ups',
    'meetings','attendance','funnels','workflows','integrations','team','access-control','masters','widgets','profile',
    'whats-new','api','assets','webinars','settings'])
$$;

/** "AI Income Mastery!" → ai-income-mastery */
create or replace function private.webinar_slugify(p text) returns text language sql immutable as $$
  select left(trim(both '-' from regexp_replace(lower(coalesce(p, '')), '[^a-z0-9]+', '-', 'g')), 60)
$$;

-- an empty slug is made from the title; taken (by another live webinar of the workspace) → -2, -3 …
create or replace function private.webinars_slug() returns trigger language plpgsql set search_path = '' as $$
declare
  base text;
  cand text;
  n int := 1;
begin
  if new.archived_at is not null then return new; end if;
  new.slug := nullif(private.webinar_slugify(new.slug), '');
  if new.slug is not null and tg_op = 'UPDATE' and new.slug is not distinct from old.slug then return new; end if;
  base := coalesce(new.slug, nullif(private.webinar_slugify(new.title), ''), 'webinar');
  if length(base) < 3 or private.webinar_slug_reserved(base) then base := left(base || '-webinar', 60); end if;
  if new.slug is not null then
    -- typed in: must be free
    if exists (select 1 from public.webinars w where w.tenant_id = new.tenant_id and w.slug = new.slug and w.id <> new.id and w.archived_at is null) then
      raise exception 'The link “%” is already used by another webinar.', new.slug using errcode = '23505';
    end if;
    new.slug := base;
    return new;
  end if;
  cand := base;
  while exists (select 1 from public.webinars w where w.tenant_id = new.tenant_id and w.slug = cand and w.id <> new.id and w.archived_at is null) loop
    n := n + 1;
    cand := left(base, 55) || '-' || n;
  end loop;
  new.slug := cand;
  return new;
end $$;
drop trigger if exists webinars_slug on public.webinars;
create trigger webinars_slug before insert or update of slug, title on public.webinars
  for each row execute function private.webinars_slug();

-- the webinars there are now get theirs (oldest first)
do $$
declare r record;
begin
  for r in select id from public.webinars where slug is null and archived_at is null order by created_at loop
    update public.webinars set slug = null, title = title where id = r.id;
  end loop;
end $$;

create unique index if not exists webinars_slug_live on public.webinars (tenant_id, slug) where archived_at is null;

/** <app>/<slug>: the Zoom link of the webinar's current date (on now, else the next one); null when there's none */
create or replace function public.webinar_link_open(p_tenant uuid, p_slug text)
returns text language sql stable security definer set search_path = '' as $$
  select e.meeting_link
  from public.webinars w
  join public.events e on e.webinar_id = w.id and not e.is_cancelled and e.meeting_link is not null
  where w.tenant_id = p_tenant and w.slug = lower(p_slug) and w.archived_at is null
    and ((e.event_date + coalesce(e.end_time, e.start_time)) at time zone 'Asia/Kolkata') > now()
  order by e.event_date, e.start_time
  limit 1
$$;
revoke all on function public.webinar_link_open(uuid, text) from public;
grant execute on function public.webinar_link_open(uuid, text) to anon, authenticated;
