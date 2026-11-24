-- Funnel → Webhooks: which step of the funnel a form is (Paid Podcast Scorecard: Opt-in form / VSL form filled)
alter table public.funnel_webhooks add column if not exists step text check (step in ('optin', 'vsl'));
comment on column public.funnel_webhooks.step is 'optin | vsl: the form''s step in the funnel (Scorecard rows); null = not set';
update public.funnel_webhooks set step = 'vsl' where tenant_id = 'cfdf9009-0f78-4041-83c1-1975ce98e234' and name = 'Update Business Details (vsl page)' and step is null;
