import { Label, TextInput } from '@/components/Field'

export function ColorField({
  id,
  label,
  value,
  onChange,
}: {
  id: string
  label: string
  value: string
  onChange: (v: string) => void
}) {
  return (
    <div>
      <Label htmlFor={id} required>
        {label}
      </Label>
      <div className="row" style={{ flexWrap: 'nowrap' }}>
        <input
          type="color"
          aria-label={`${label} picker`}
          value={/^#[0-9a-fA-F]{6}$/.test(value) ? value : '#000000'}
          onChange={(e) => onChange(e.target.value)}
          className="input"
          style={{ width: 56, padding: 4, cursor: 'pointer', flexShrink: 0 }}
        />
        <TextInput id={id} value={value} onChange={(e) => onChange(e.target.value.trim())} className="input-mono" />
      </div>
    </div>
  )
}
