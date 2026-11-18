-- Funnel → Payments: the price this funnel sells at; the tab lists Razorpay payments of that amount from the funnel's leads
alter table public.funnels add column if not exists payment_amount numeric;
