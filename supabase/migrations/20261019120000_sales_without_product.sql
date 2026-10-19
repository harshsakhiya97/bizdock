-- A sale can be recorded without a product or billing company (customer + amount + payment).
-- create_sale(): product_id / billing_company_id optional, plan defaults to 'full'.
alter table public.sales alter column product_id drop not null;
alter table public.sales alter column billing_company_id drop not null;
-- (function body applied as sales_without_product; same as 20261012160000 create_sale with:
--   plan := coalesce(nullif(p->>'plan',''),'full'); product looked up only when given; bc := nullif(p->>'billing_company_id','')::uuid
--   checked only when given; valid_until null without a product; payments.billing_company_id = bc)
