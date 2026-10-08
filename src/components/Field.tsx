import { useState, type InputHTMLAttributes, type ReactNode } from 'react'
import { Eye, EyeOff } from 'lucide-react'
import { cn } from '@/lib/cn'

export function Label({ htmlFor, required, children }: { htmlFor: string; required?: boolean; children: ReactNode }) {
  return (
    <label htmlFor={htmlFor} className="mb-1.5 block text-sm font-semibold text-gray-900">
      {children}
      {required && <span className="text-brand">*</span>}
    </label>
  )
}

type InputProps = InputHTMLAttributes<HTMLInputElement> & { icon?: ReactNode }

export function TextInput({ icon, className, ...props }: InputProps) {
  return (
    <div className="relative">
      {icon && (
        <span className="pointer-events-none absolute top-1/2 left-3.5 -translate-y-1/2 text-gray-400 [&_svg]:size-4">
          {icon}
        </span>
      )}
      <input
        {...props}
        className={cn(
          'h-11 w-full rounded-lg border border-gray-300 bg-white px-3.5 text-sm outline-none placeholder:text-gray-400',
          'focus:border-brand focus:ring-2 focus:ring-brand/15',
          icon ? 'pl-10' : '',
          className,
        )}
      />
    </div>
  )
}

export function PasswordInput({ icon, className, ...props }: Omit<InputProps, 'type'>) {
  const [show, setShow] = useState(false)
  return (
    <div className="relative">
      <TextInput {...props} icon={icon} type={show ? 'text' : 'password'} className={cn('pr-11', className)} />
      <button
        type="button"
        onClick={() => setShow((s) => !s)}
        aria-label={show ? 'Hide password' : 'Show password'}
        className="absolute top-1/2 right-3 -translate-y-1/2 text-gray-400 hover:text-gray-600"
      >
        {show ? <Eye className="size-4" /> : <EyeOff className="size-4" />}
      </button>
    </div>
  )
}
