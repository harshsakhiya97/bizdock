-- Masters → Follow-up outcomes: "Comment required" — Log a call / Log follow-up need Comments for these outcomes.
-- Starting values: Connected – interested, Call back later, Payment promised (every workspace's outcome of that name).
alter table public.follow_up_outcomes add column if not exists comment_required boolean not null default false;
update public.follow_up_outcomes set comment_required = true
 where lower(regexp_replace(name, '\s*[–—-]\s*', ' - ', 'g')) in ('connected - interested', 'call back later', 'payment promised');
