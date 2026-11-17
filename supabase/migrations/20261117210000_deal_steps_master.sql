-- Masters → Brand deal steps: the steps of a Brand Deal (name, order, on / off). A deal keeps the steps ticked as
-- bookings.deal_steps = [{ "step_id": "<deal_steps.id>", "at": "<iso>", "by": "<member id>" }, …]
create table public.deal_steps (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  name text not null,
  sort_order int not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);
create index deal_steps_tenant on public.deal_steps (tenant_id, sort_order);
alter table public.deal_steps enable row level security;
create policy "deal_steps: read" on public.deal_steps for select using (private.is_member(tenant_id) or private.is_platform_owner());
create policy "deal_steps: write" on public.deal_steps for all
  using (private.has_permission(tenant_id, 'masters', 'edit')) with check (private.has_permission(tenant_id, 'masters', 'edit'));

-- every workspace starts with the 8 steps (in English)
insert into public.deal_steps (tenant_id, name, sort_order)
select t.id, s.name, s.n
  from public.tenants t
  cross join (values (1, 'Deal received'), (2, 'Script with the writer'), (3, 'Script sent to the brand for approval'), (4, 'Shoot'),
                     (5, 'Video with the editor'), (6, 'Video sent to the brand for approval'), (7, 'Live · payment pending'), (8, 'Payment received')) s(n, name);

-- deals ticked so far by step number → by step id
update public.bookings b
   set deal_steps = coalesce((
     select jsonb_agg(jsonb_build_object('step_id', d.id, 'at', e ->> 'at', 'by', e -> 'by'))
       from jsonb_array_elements(b.deal_steps) e
       join public.deal_steps d on d.tenant_id = b.tenant_id and d.sort_order = (e ->> 'step')::int), '[]'::jsonb)
 where jsonb_array_length(b.deal_steps) > 0 and (b.deal_steps -> 0) ? 'step';
