-- Every branch gets a unique code (unique within the tenant) and a short name.
alter table public.branches
  add column code       text not null check (code ~ '^[A-Z0-9-]{2,12}$'),
  add column short_name text not null check (length(trim(short_name)) between 1 and 20);

create unique index branches_tenant_code_key on public.branches (tenant_id, code);
