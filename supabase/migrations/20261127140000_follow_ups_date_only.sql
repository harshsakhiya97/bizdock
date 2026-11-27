-- Follow-ups are picked by date only (due all that day, overdue from the next day): stored at 11:59 pm India time.
-- The pending ones from before keep their date and move to that day's 11:59 pm — without rewriting AI Insights
-- (bizdock.quiet, now also honoured by the follow-up / call / message rows' insight trigger).
set local lock_timeout = '15s';

create or replace function private.lead_insight_on_row() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if coalesce(current_setting('bizdock.quiet', true), '') = '1' then return null; end if;
  if tg_op = 'UPDATE' and to_jsonb(old) - 'updated_at' = to_jsonb(new) - 'updated_at' then return null; end if;
  perform private.lead_insight_touch(new.lead_id, new.tenant_id);
  if tg_op = 'UPDATE' and old.lead_id is distinct from new.lead_id then perform private.lead_insight_touch(old.lead_id, old.tenant_id); end if;
  return null;
end $$;

select set_config('bizdock.quiet', '1', true);
update public.follow_ups
   set due_at = (((due_at at time zone 'Asia/Kolkata')::date + time '23:59') at time zone 'Asia/Kolkata')
 where status = 'pending'
   and to_char(due_at at time zone 'Asia/Kolkata', 'HH24:MI') <> '23:59';
select set_config('bizdock.quiet', '', true);
