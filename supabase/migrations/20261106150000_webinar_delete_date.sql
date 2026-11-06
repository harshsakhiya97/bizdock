-- Delete only one date of a webinar: that date is kept in skipped_dates (so it isn't made again)
-- and the webinar's next date follows.
alter table public.webinars add column if not exists skipped_dates date[] not null default '{}';

create or replace function private.webinar_next_date(w public.webinars, p_after date) returns date
language plpgsql stable set search_path = '' as $$
declare
  d date;
  today date := (now() at time zone 'Asia/Kolkata')::date;
  skip date[] := coalesce(w.skipped_dates, '{}');
begin
  if w.repeat = 'once' then
    if p_after is not null and w.first_date <= p_after then return null; end if;
    if w.first_date = any (skip) then return null; end if;
    if ((w.first_date + w.start_time) at time zone 'Asia/Kolkata') <= now() then return null; end if;
    return w.first_date;
  elsif w.repeat = 'dates' then
    select min(x) into d from unnest(w.dates) x
     where (p_after is null or x > p_after) and not (x = any (skip)) and ((x + w.start_time) at time zone 'Asia/Kolkata') > now();
    return d;
  end if;
  -- weekly
  if coalesce(array_length(w.weekdays, 1), 0) = 0 then return null; end if;
  d := greatest(w.first_date, coalesce(p_after + 1, w.first_date), today);
  for i in 0..21 loop
    if w.stop_date is not null and d > w.stop_date then return null; end if;
    if extract(dow from d)::int = any (w.weekdays) and not (d = any (skip)) and ((d + w.start_time) at time zone 'Asia/Kolkata') > now() then return d; end if;
    d := d + 1;
  end loop;
  return null;
end $$;
