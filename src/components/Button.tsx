import type { ButtonHTMLAttributes } from 'react'
import { cn } from '@/lib/cn'

type Variant = 'primary' | 'dark' | 'outline' | 'danger' | 'ghost'

/** Theme-kit button: .btn + .btn-primary / .btn-dark / .btn-outline / .btn-danger / .btn-ghost */
export function Button({
  variant = 'primary',
  size,
  icon,
  className,
  type = 'button',
  ...props
}: ButtonHTMLAttributes<HTMLButtonElement> & { variant?: Variant; size?: 'sm'; icon?: boolean }) {
  return (
    <button
      type={type}
      {...props}
      className={cn('btn', `btn-${variant}`, size === 'sm' && 'btn-sm', icon && 'btn-icon', className)}
    />
  )
}
