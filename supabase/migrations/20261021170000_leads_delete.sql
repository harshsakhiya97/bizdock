-- Leads can be deleted (Tech Support / Owner always; others with leads.delete). Follow-ups, activities,
-- submissions and messages go with the lead; bookings keep their details (lead link cleared).
create policy "leads: delete" on public.leads for delete to authenticated
  using (private.can_see_lead(tenant_id, business_id, owner_id) and private.has_permission(tenant_id, 'leads', 'delete'));
grant delete on public.leads to authenticated;
