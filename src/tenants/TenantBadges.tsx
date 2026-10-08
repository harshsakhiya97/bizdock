import { cn } from '@/lib/cn'
import type { TenantRow } from './types'

/** Tenant logo, or its first letter on its own colour. */
export function TenantIcon({
  tenant,
  size = 36,
}: {
  tenant: Pick<TenantRow, 'app_name' | 'logo_url' | 'primary_color'>
  size?: number
}) {
  if (tenant.logo_url) {
    return (
      <img
        src={tenant.logo_url}
        alt=""
        className="shrink-0 rounded-[22%] border border-gray-200 bg-white object-contain"
        style={{ width: size, height: size }}
      />
    )
  }
  return (
    <div
      className="grid shrink-0 place-items-center rounded-[22%] font-bold text-white"
      style={{ width: size, height: size, background: tenant.primary_color, fontSize: size * 0.45 }}
    >
      {tenant.app_name.trim().charAt(0).toUpperCase()}
    </div>
  )
}

export function StatusBadge({ status }: { status: TenantRow['status'] }) {
  return (
    <span
      className={cn(
        'rounded-md px-2 py-0.5 text-xs font-medium',
        status === 'active' ? 'bg-emerald-50 text-emerald-700' : 'bg-amber-50 text-amber-700',
      )}
    >
      {status === 'active' ? 'Active' : 'Suspended'}
    </span>
  )
}
