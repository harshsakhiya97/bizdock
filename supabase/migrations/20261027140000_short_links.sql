-- Short links made by a workflow's Short link step: <app>/<code> opens the long URL (lead fields filled in).
create table if not exists public.short_links (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  code text not null unique check (code ~ '^[A-Za-z0-9]{7}$'),
  url text not null check (url ~* '^https?://'),
  lead_id uuid references public.leads(id) on delete set null,
  workflow_id uuid references public.workflows(id) on delete set null,
  run_id uuid references public.workflow_runs(id) on delete set null,
  clicks int not null default 0,
  last_click_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists short_links_lead on public.short_links (lead_id);
alter table public.short_links enable row level security;
create policy "short_links: read" on public.short_links for select to authenticated
  using (private.has_permission(tenant_id, 'workflows', 'view'));

-- public: the long URL for a code (counts the click)
create or replace function public.short_link_open(p_code text)
returns text language plpgsql security definer set search_path = '' as $$
declare v text;
begin
  update public.short_links set clicks = clicks + 1, last_click_at = now()
  where code = p_code returning url into v;
  return v;
end $$;
revoke all on function public.short_link_open(text) from public;
grant execute on function public.short_link_open(text) to anon, authenticated;
