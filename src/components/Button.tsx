import type { ButtonHTMLAttributes } from 'react'
import { cn } from '@/lib/cn'

type Variant = 'primary' | 'dark' | 'outline' | 'danger' | 'ghost'

const styles: Record<Variant, string> = {
  primary: 'bg-brand text-white hover:bg-brand-hover',
  dark: 'bg-navy text-white hover:bg-navy-hover',
  outline: 'border border-gray-300 bg-white text-gray-900 hover:bg-gray-50',
  danger: 'bg-red-600 text-white hover:bg-red-700',
  ghost: 'text-gray-700 hover:bg-gray-100',
}

export function Button({
  variant = 'primary',
  className,
  ...props
}: ButtonHTMLAttributes<HTMLButtonElement> & { variant?: Variant }) {
  return (
    <button
      {...props}
      className={cn(
        'inline-flex h-9 items-center justify-center gap-2 rounded-lg px-4 text-sm font-semibold transition-colors disabled:cursor-not-allowed disabled:opacity-50 [&_svg]:size-4',
        styles[variant],
        className,
      )}
    />
  )
}
