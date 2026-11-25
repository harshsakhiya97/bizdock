-- Razorpay → auto-capture (the sync every 5 minutes): a payment still "authorized" is captured once — when it was tried
-- and Razorpay's refusal, if any.
alter table public.razorpay_payments add column if not exists capture_tried_at timestamptz;
alter table public.razorpay_payments add column if not exists capture_error text;
