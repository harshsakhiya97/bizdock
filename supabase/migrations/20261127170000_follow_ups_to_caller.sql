-- The next follow-up belongs to whoever logged the call. Pending follow-ups that were set by a call (made by the same
-- person, at that call) but assigned to someone else (the lead owner / the earlier assignee) move to that caller.
select set_config('bizdock.quiet', '1', true);
with last_done as (
  select distinct on (lead_id) lead_id, completed_by, completed_at
    from public.follow_ups where status = 'done' order by lead_id, completed_at desc
)
update public.follow_ups p set assigned_to = d.completed_by
  from last_done d
 where d.lead_id = p.lead_id and p.status = 'pending'
   and p.assigned_to is distinct from d.completed_by
   and p.created_by = d.completed_by and p.created_at >= d.completed_at - interval '2 minutes';
select set_config('bizdock.quiet', '', true);
