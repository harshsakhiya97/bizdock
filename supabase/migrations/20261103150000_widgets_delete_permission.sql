-- Deleting a widget archives it (an update): allowed with widgets edit or delete.
drop policy "widgets: edit" on public.widgets;
create policy "widgets: edit" on public.widgets for update to authenticated
  using (private.has_permission(tenant_id, 'widgets', 'edit') or private.has_permission(tenant_id, 'widgets', 'delete'))
  with check (private.has_permission(tenant_id, 'widgets', 'edit') or private.has_permission(tenant_id, 'widgets', 'delete'));
