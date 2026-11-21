-- One-time imports: a script on Harsh's Mac sends rows here with a short-lived token; nothing reaches the app's tables
-- until they are moved in by hand. Rows land in private.import_rows under the token's purpose.
create or replace function public.import_put(p_token text, p_kind text, p_rows jsonb)
returns integer
language plpgsql security definer
set search_path to ''
as $function$
declare pur text; n int;
begin
  select purpose into pur from private.import_tokens where token = p_token and expires_at > now();
  if pur is null then raise exception 'This import link has expired'; end if;
  insert into private.import_rows (purpose, kind, data) select pur, p_kind, x from jsonb_array_elements(p_rows) x;
  get diagnostics n = row_count;
  return n;
end $function$;
revoke all on function public.import_put(text, text, jsonb) from public;
grant execute on function public.import_put(text, text, jsonb) to anon, authenticated;
