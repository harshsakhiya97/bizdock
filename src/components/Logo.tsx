import logoMark from '@/assets/logo-mark.png'
import { cn } from '@/lib/cn'

/** The BizDock app icon (kept as is). */
export function LogoMark({ size = 34, className }: { size?: number; className?: string }) {
  return (
    <img
      src={logoMark}
      alt="BizDock"
      width={size}
      height={size}
      className={cn('logo-img', className)}
      style={{ width: size, height: size, background: 'var(--ink)' }}
    />
  )
}

/** Theme-kit brand lockup: mark + "BIZDOCK" with the tagline under it. */
export function LogoLockup() {
  return (
    <div className="brand-lockup">
      <LogoMark size={34} />
      <div className="brand-name">
        BizDock
        <span>Business Suite</span>
      </div>
    </div>
  )
}
