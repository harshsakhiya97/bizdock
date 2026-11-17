-- Brand Deals: the steps of a deal (1 Deal aayi … 8 Payment aa gaya), ticked in the deal; the list shows the latest.
-- [{ "step": 1, "at": "<iso>", "by": "<member id>" }, …]
alter table public.bookings add column deal_steps jsonb not null default '[]'::jsonb;
