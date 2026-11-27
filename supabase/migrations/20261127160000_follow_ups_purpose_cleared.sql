-- Follow-ups no longer have a Purpose (removed from every form and screen); the 30 saved ones are emptied, as asked.
-- AI Insights are left alone (bizdock.quiet).
select set_config('bizdock.quiet', '1', true);
update public.follow_ups set purpose = null where purpose is not null;
select set_config('bizdock.quiet', '', true);
