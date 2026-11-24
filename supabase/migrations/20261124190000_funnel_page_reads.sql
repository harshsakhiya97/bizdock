-- A funnel you can see (Funnels → view): everything on its page can be read too — its workflows (and their webhooks /
-- runs) and the Razorpay payments of its Payments tab / report — without the separate Workflows / Payments view
-- permissions. Facebook / Google ads, landing pages, webhooks and sheets already follow Funnels → view. Extra read
-- policies only; the module pages, add / edit / delete keep their own permissions.
drop policy if exists "workflows: funnel page read" on public.workflows;
create policy "workflows: funnel page read" on public.workflows for select to authenticated
  using ((funnel_id is not null or event_id is not null) and private.has_permission(tenant_id, 'funnels', 'view'));

drop policy if exists "workflow_hooks: funnel page read" on public.workflow_hooks;
create policy "workflow_hooks: funnel page read" on public.workflow_hooks for select to authenticated
  using (private.has_permission(tenant_id, 'funnels', 'view')
         and exists (select 1 from public.workflows w where w.id = workflow_id and (w.funnel_id is not null or w.event_id is not null)));

drop policy if exists "workflow_runs: funnel page read" on public.workflow_runs;
create policy "workflow_runs: funnel page read" on public.workflow_runs for select to authenticated
  using (private.has_permission(tenant_id, 'funnels', 'view')
         and exists (select 1 from public.workflows w where w.id = workflow_id and (w.funnel_id is not null or w.event_id is not null)));

drop policy if exists "razorpay_payments: funnel page read" on public.razorpay_payments;
create policy "razorpay_payments: funnel page read" on public.razorpay_payments for select to authenticated
  using (private.has_permission(tenant_id, 'funnels', 'view'));
