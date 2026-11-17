-- A follow-up marked done from the app is stamped with the server's time, not the computer's: a computer set to the
-- wrong time zone (Alka's, US Pacific with an India clock) logged calls 13.5 hours ahead. A call logged straight away
-- (due = done, a new row) gets the server time for both. Imports and the server keep the times they send.
create or replace function private.follow_up_server_time() returns trigger language plpgsql set search_path to '' as $$
begin
  if (select auth.uid()) is null then return new; end if;
  if new.status = 'done' and (tg_op = 'INSERT' or old.status is distinct from 'done' or new.completed_at is distinct from old.completed_at) then
    if tg_op = 'INSERT' and new.due_at is not distinct from new.completed_at then new.due_at := now(); end if;
    new.completed_at := now();
  end if;
  return new;
end $$;
drop trigger if exists follow_ups_server_time on public.follow_ups;
create trigger follow_ups_server_time before insert or update on public.follow_ups for each row execute function private.follow_up_server_time();

-- Alka's calls logged 16–17 Nov with her computer 13 h 30 min ahead, and the one follow-up she scheduled that way
update public.follow_ups set due_at = due_at - interval '13 hours 30 minutes', completed_at = completed_at - interval '13 hours 30 minutes'
 where completed_by = '35e009cf-aaf2-4b2a-a14e-6ae4cc8a7b50' and due_at = completed_at
   and completed_at - created_at between interval '13 hours 20 minutes' and interval '13 hours 40 minutes';
update public.follow_ups set due_at = due_at - interval '13 hours 30 minutes'
 where created_by = '35e009cf-aaf2-4b2a-a14e-6ae4cc8a7b50' and status = 'pending'
   and to_char(due_at at time zone 'Asia/Kolkata', 'HH24:MI') = '00:30';
