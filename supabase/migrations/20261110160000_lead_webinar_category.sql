-- The lead's webinar category (its latest, by name): kept on the lead when the webinar analytics step categorizes it,
-- so a Switch path checks "Webinar category equals Super Hot".
alter table public.leads add column if not exists webinar_category text;

create or replace function private.lead_webinar_category() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.category_name is not null and (tg_op = 'INSERT' or new.category_name is distinct from old.category_name) then
    update public.leads set webinar_category = new.category_name where id = new.lead_id;
  end if;
  return new;
end $$;
drop trigger if exists webinar_registrations_lead_category on public.webinar_registrations;
create trigger webinar_registrations_lead_category after insert or update of category_name on public.webinar_registrations
  for each row execute function private.lead_webinar_category();

-- leads already categorized: their latest
update public.leads l set webinar_category = r.category_name
  from (select distinct on (lead_id) lead_id, category_name from public.webinar_registrations
         where category_name is not null order by lead_id, categorized_at desc nulls last) r
 where r.lead_id = l.id and l.webinar_category is null;
