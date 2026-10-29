-- Meeting webhooks no longer book the meeting themselves: the post is kept on the lead (submission with its
-- date / time / team member + an activity note) and starts the funnel's workflows, where a Zoom / meeting
-- step books it. Meet with / Zoom on the webhook are no longer used.
do $$
declare
  src text;
  a int;
  b int;
begin
  src := pg_get_functiondef('public.webhook_submit(text,jsonb)'::regprocedure);
  a := position('  elsif w.action = ''create_meeting'' then' in src);
  b := position('  else -- purchase' in src);
  if a = 0 or b = 0 or b < a then raise exception 'webhook_submit: create_meeting branch not found'; end if;
  src := substr(src, 1, a - 1) || $branch$  elsif w.action = 'create_meeting' then
    -- only logged here: the meeting is booked by a workflow step
    t0 := private.parse_when(d ->> 'meeting_start');
    if t0 is null then raise exception 'Missing or unreadable meeting_start (date and time of the meeting).'; end if;
    host := nullif(trim(coalesce(d ->> 'meeting_team_member', '')), '');
    v_note := 'Meeting request from ' || w.name || ' for ' || to_char(t0 at time zone 'Asia/Kolkata', 'DD Mon YYYY, HH12:MI AM')
              || coalesce(' · with ' || host, '');

$branch$ || substr(src, b);
  execute src;
end $$;
