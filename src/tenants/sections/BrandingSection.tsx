import { useRef, useState } from 'react'
import { ImageUp, Trash2 } from 'lucide-react'
import { Button } from '@/components/Button'
import { removeBranding, updateTenant, uploadBranding } from '../api'
import { ColorField } from '../ColorField'
import { TenantIcon } from '../TenantBadges'
import { isValidHexColor } from '../types'
import { SaveStatus, SectionHeader, type SectionProps } from './shared'

const MAX_BYTES = 2 * 1024 * 1024

export function BrandingSection({ tenant, onSaved }: SectionProps) {
  const [color, setColor] = useState(tenant.primary_color)
  const [error, setError] = useState<string | null>(null)
  const [saved, setSaved] = useState(false)
  const [busy, setBusy] = useState<string | null>(null)

  async function run(label: string, fn: () => Promise<typeof tenant>) {
    setBusy(label)
    setError(null)
    setSaved(false)
    try {
      onSaved(await fn())
      setSaved(true)
    } catch (err) {
      setError((err as Error).message)
    } finally {
      setBusy(null)
    }
  }

  function saveColor() {
    if (!isValidHexColor(color)) return setError('Pick a colour like #2b5fe8.')
    void run('color', () => updateTenant(tenant.id, { primary_color: color }))
  }

  const preview = { ...tenant, primary_color: isValidHexColor(color) ? color : tenant.primary_color }

  return (
    <div className="max-w-[560px]">
      <SectionHeader title="Branding" description="What the tenant's users see: logo, favicon and theme colour." />

      {/* live preview */}
      <div className="mb-6 flex items-center gap-4 rounded-xl border border-gray-200 p-4">
        <TenantIcon tenant={preview} size={56} />
        <div className="flex-1">
          <div className="font-extrabold tracking-tight uppercase">{tenant.app_name}</div>
          <div className="mt-2 flex gap-2">
            <span
              className="rounded-md px-3 py-1.5 text-xs font-semibold text-white"
              style={{ background: preview.primary_color }}
            >
              Primary button
            </span>
            <span
              className="rounded-md px-3 py-1.5 text-xs font-semibold"
              style={{
                color: preview.primary_color,
                background: `color-mix(in oklab, ${preview.primary_color} 10%, white)`,
              }}
            >
              Selected tab
            </span>
          </div>
        </div>
      </div>

      <div className="space-y-6">
        <div>
          <ColorField id="b-color" label="Theme colour" value={color} onChange={setColor} />
          <Button
            className="mt-3"
            variant="dark"
            onClick={saveColor}
            disabled={busy !== null || color === tenant.primary_color}
          >
            {busy === 'color' ? 'Saving…' : 'Save colour'}
          </Button>
        </div>

        <ImageField
          label="Logo"
          hint="Square image works best (PNG, JPG, WEBP or SVG, up to 2 MB). Shown on the login page and sidebar."
          url={tenant.logo_url}
          busy={busy === 'logo'}
          disabled={busy !== null}
          onPick={(file) => run('logo', () => uploadBranding(tenant, 'logo', file))}
          onRemove={() => run('logo', () => removeBranding(tenant, 'logo'))}
          onError={setError}
        />
        <ImageField
          label="Favicon"
          hint="The small icon in the browser tab (PNG, SVG or ICO). If empty, the logo is used."
          url={tenant.favicon_url}
          busy={busy === 'favicon'}
          disabled={busy !== null}
          onPick={(file) => run('favicon', () => uploadBranding(tenant, 'favicon', file))}
          onRemove={() => run('favicon', () => removeBranding(tenant, 'favicon'))}
          onError={setError}
        />

        <SaveStatus error={error} saved={saved} />
      </div>
    </div>
  )
}

function ImageField({
  label,
  hint,
  url,
  busy,
  disabled,
  onPick,
  onRemove,
  onError,
}: {
  label: string
  hint: string
  url: string | null
  busy: boolean
  disabled: boolean
  onPick: (file: File) => void
  onRemove: () => void
  onError: (msg: string) => void
}) {
  const input = useRef<HTMLInputElement>(null)
  return (
    <div>
      <span className="mb-1.5 block text-sm font-semibold">{label}</span>
      <div className="flex items-center gap-4">
        <div className="grid size-16 shrink-0 place-items-center overflow-hidden rounded-xl border border-dashed border-gray-300 bg-gray-50">
          {url ? (
            <img src={url} alt="" className="size-full object-contain" />
          ) : (
            <ImageUp className="size-5 text-gray-400" />
          )}
        </div>
        <div className="flex gap-2">
          <input
            ref={input}
            type="file"
            accept="image/png,image/jpeg,image/webp,image/svg+xml,image/x-icon,.ico"
            className="hidden"
            onChange={(e) => {
              const file = e.target.files?.[0]
              e.target.value = ''
              if (!file) return
              if (file.size > MAX_BYTES) return onError(`${label} must be 2 MB or smaller.`)
              onPick(file)
            }}
          />
          <Button variant="outline" onClick={() => input.current?.click()} disabled={disabled}>
            <ImageUp /> {busy ? 'Uploading…' : url ? 'Replace' : 'Upload'}
          </Button>
          {url && (
            <Button variant="ghost" onClick={onRemove} disabled={disabled} className="text-red-600">
              <Trash2 /> Remove
            </Button>
          )}
        </div>
      </div>
      <p className="mt-1.5 text-xs text-gray-500">{hint}</p>
    </div>
  )
}
