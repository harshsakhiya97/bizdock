-- A webinar's lead categories (Lead categories tab): name + minimum minutes attended, and "Not joined" (min null).
-- After each date a lead gets the highest category their minutes reach; joined but under the lowest → the lowest;
-- didn't join → Not joined. The registration keeps the category's key and its name at that time.
alter table public.webinars add column if not exists categories jsonb not null default
  '[{"key":"super_hot","name":"Super Hot","min":90},{"key":"hot","name":"Hot","min":60},{"key":"warm","name":"Warm","min":30},{"key":"cold","name":"Cold","min":1},{"key":"not_joined","name":"Not joined","min":null}]'::jsonb;

alter table public.webinar_registrations drop constraint if exists webinar_registrations_category_check;
alter table public.webinar_registrations add column if not exists category_name text;
update public.webinar_registrations set category_name = case category when 'super_hot' then 'Super Hot' when 'hot' then 'Hot' when 'warm' then 'Warm' when 'cold' then 'Cold' end
 where category is not null and category_name is null;
