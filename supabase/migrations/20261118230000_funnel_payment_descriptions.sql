-- Funnel → Payments: the Razorpay product names (payment description) this funnel sells; the tab lists those payments
-- from the funnel's leads (phone / email). Replaces payment_amount (left in place, no longer used).
alter table public.funnels add column if not exists payment_descriptions text[] not null default '{}';
