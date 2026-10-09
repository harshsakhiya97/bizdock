-- GST is optional for a business; a branch can use the business GST or its own.
alter table public.businesses
  add column has_gst boolean not null default false;

update public.businesses set has_gst = true where gst_number is not null or legal_name is not null;

alter table public.branches
  add column own_gst     boolean not null default false,
  add column legal_name  text,
  add column gst_number  text;
