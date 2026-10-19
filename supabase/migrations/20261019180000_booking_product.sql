-- A booking can be for a product (its price fills the booking amount).
alter table public.bookings add column product_id uuid references public.products (id) on delete set null;
create index bookings_product_idx on public.bookings (product_id);
