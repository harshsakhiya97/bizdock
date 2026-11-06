-- Login with email or mobile number: a mobile number (and its password) gives back the account's email, which the app
-- then logs in with as usual. Only a right password gets the email (no looking up who has a number), and wrong tries are
-- limited (10 per number in 15 minutes).
create table if not exists private.login_attempts (
  phone text not null,
  at timestamptz not null default now()
);
create index if not exists login_attempts_phone on private.login_attempts (phone, at);

create or replace function public.login_email_for_phone(p_tenant uuid, p_phone text, p_password text) returns text
language plpgsql security definer set search_path = '' as $$
declare
  ph text := right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10);
  em text;
  n int;
begin
  if length(ph) <> 10 or coalesce(p_password, '') = '' then return null; end if;
  delete from private.login_attempts where at < now() - interval '1 day';
  if (select count(*) from private.login_attempts where phone = ph and at > now() - interval '15 minutes') >= 10 then
    raise exception 'Too many tries with this mobile number. Try again in 15 minutes.';
  end if;
  -- an active member of this workspace with that number (only if one has it)
  select count(*), max(u.email) into n, em
    from public.profiles p
    join public.tenant_members m on m.user_id = p.id and m.tenant_id = p_tenant and m.status = 'active'
    join auth.users u on u.id = p.id
   where right(regexp_replace(coalesce(p.phone, ''), '\D', '', 'g'), 10) = ph
     and u.encrypted_password = extensions.crypt(p_password, u.encrypted_password);
  if n = 1 then return em; end if;
  insert into private.login_attempts (phone) values (ph);
  return null;
end $$;
revoke all on function public.login_email_for_phone(uuid, text, text) from public;
grant execute on function public.login_email_for_phone(uuid, text, text) to anon, authenticated;
