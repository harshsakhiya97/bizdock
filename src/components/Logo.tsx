import logoMark from '@/assets/logo-mark.png'
import { cn } from '@/lib/cn'

export function LogoMark({ size = 34, className }: { size?: number; className?: string }) {
  return (
    <img
      src={logoMark}
      alt="BizDock"
      width={size}
      height={size}
      className={cn('shrink-0 rounded-[22%] bg-navy', className)}
      style={{ width: size, height: size }}
    />
  )
}

/** Mark + "BIZDOCK" wordmark, like the Muzic Lover sidebar header. */
export function LogoLockup({ size = 34, tagline = true }: { size?: number; tagline?: boolean }) {
  return (
    <div className="flex items-center gap-2.5">
      <LogoMark size={size} />
      <div className="leading-none">
        <div className="text-[15px] font-extrabold tracking-tight text-gray-900">BIZDOCK</div>
        {tagline && (
          <div className="mt-1 text-[9px] font-bold tracking-[0.2em] text-brand">BUSINESS SUITE</div>
        )}
      </div>
    </div>
  )
}
