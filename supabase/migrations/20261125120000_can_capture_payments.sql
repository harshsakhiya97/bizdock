-- Payments → Razorpay: who may press Capture on an authorized payment (Payments → Verify or Add, or System Connections)
create or replace function public.can_capture_payments(p_tenant uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select private.has_permission(p_tenant, 'payments', 'verify') or private.has_permission(p_tenant, 'payments', 'add')
      or private.has_permission(p_tenant, 'settings', 'edit')
$$;
revoke all on function public.can_capture_payments(uuid) from public, anon;
grant execute on function public.can_capture_payments(uuid) to authenticated;
