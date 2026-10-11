import {
  useState,
  type InputHTMLAttributes,
  type ReactNode,
  type SelectHTMLAttributes,
  type TextareaHTMLAttributes,
} from 'react'
import { Eye, EyeOff } from 'lucide-react'
import { cn } from '@/lib/cn'

/* Form fields from the theme kit: .field-label, .input-wrap, .input, .input-action */

export function Label({ htmlFor, required, children }: { htmlFor?: string; required?: boolean; children: ReactNode }) {
  return (
    <label htmlFor={htmlFor} className="field-label">
      {children}
      {required && <span className="req">*</span>}
    </label>
  )
}

/** Grey helper text under a field. */
export function Hint({ children }: { children: ReactNode }) {
  return <p className="field-hint">{children}</p>
}

/** Grey uppercase group title with an optional one-line description. */
export function FormSection({
  title,
  description,
  children,
}: {
  title: string
  description?: string
  children: ReactNode
}) {
  return (
    <section className="form-section">
      <div className="form-section-head">
        <h4>{title}</h4>
        {description && <p>{description}</p>}
      </div>
      {children}
    </section>
  )
}

type InputProps = InputHTMLAttributes<HTMLInputElement> & { icon?: ReactNode }

export function TextInput({ icon, className, ...props }: InputProps) {
  return (
    <div className="input-wrap">
      {icon && <span className="input-icon">{icon}</span>}
      <input {...props} className={cn('input', className)} />
    </div>
  )
}

export function TextArea({ className, rows = 3, ...props }: TextareaHTMLAttributes<HTMLTextAreaElement>) {
  return <textarea rows={rows} {...props} className={cn('input', className)} />
}

export function Select({ className, children, ...props }: SelectHTMLAttributes<HTMLSelectElement>) {
  return (
    <select {...props} className={cn('input', className)}>
      {children}
    </select>
  )
}

export function PasswordInput({ icon, className, ...props }: Omit<InputProps, 'type'>) {
  const [show, setShow] = useState(false)
  return (
    <div className="input-wrap">
      {icon && <span className="input-icon">{icon}</span>}
      <input {...props} type={show ? 'text' : 'password'} className={cn('input has-action', className)} />
      <button
        type="button"
        className="input-action"
        onClick={() => setShow((s) => !s)}
        aria-label={show ? 'Hide password' : 'Show password'}
      >
        {show ? <Eye size={16} /> : <EyeOff size={16} />}
      </button>
    </div>
  )
}

/** Checkbox with a title and optional grey description, e.g. "Registered for GST?". */
export function Checkbox({
  id,
  checked,
  onChange,
  label,
  description,
}: {
  id: string
  checked: boolean
  onChange: (checked: boolean) => void
  label: string
  description?: string
}) {
  return (
    <label htmlFor={id} className="check">
      <input id={id} type="checkbox" checked={checked} onChange={(e) => onChange(e.target.checked)} />
      <span>
        <b>{label}</b>
        {description && <small>{description}</small>}
      </span>
    </label>
  )
}
