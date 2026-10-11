import type { TenantRow } from './types'

/** Client logo, or its first letter on its own colour. */
export function TenantIcon({
  tenant,
  size = 34,
}: {
  tenant: Pick<TenantRow, 'app_name' | 'logo_url' | 'primary_color'>
  size?: number
}) {
  if (tenant.logo_url) {
    return (
      <span className="thumb has-img" style={{ width: size, height: size }}>
        <img src={tenant.logo_url} alt="" />
      </span>
    )
  }
  return (
    <span
      className="thumb"
      style={{ width: size, height: size, background: tenant.primary_color, color: '#fff', fontSize: size * 0.42 }}
    >
      {tenant.app_name.trim().charAt(0).toUpperCase()}
    </span>
  )
}

export function StatusBadge({ status }: { status: TenantRow['status'] }) {
  return status === 'active' ? (
    <span className="badge badge-success">Active</span>
  ) : (
    <span className="badge badge-warning">Suspended</span>
  )
}
