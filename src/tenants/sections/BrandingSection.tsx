import { useRef, useState } from 'react'
import { ImageUp, Trash2 } from 'lucide-react'
import { Button } from '@/components/Button'
import { Hint } from '@/components/Field'
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
    <>
      <SectionHeader title="Branding" description="What the client's users see: logo, favicon and theme colour." />

      <div className="stack" style={{ maxWidth: 560 }}>
        {/* live preview */}
        <div className="posting-head" style={{ justifyContent: 'flex-start', gap: 14 }}>
          <TenantIcon tenant={preview} size={52} />
          <div className="stack" style={{ gap: 8 }}>
            <div className="brand-name">{tenant.app_name}</div>
            <div className="row" style={{ gap: 8 }}>
              <span className="btn btn-sm" style={{ background: preview.primary_color, color: '#fff', cursor: 'default' }}>
                Primary button
              </span>
              <span
                className="tab is-active"
                style={{
                  color: preview.primary_color,
                  borderColor: preview.primary_color,
                  background: `color-mix(in oklab, ${preview.primary_color} 9%, white)`,
                  cursor: 'default',
                  display: 'inline-flex',
                  alignItems: 'center',
                }}
              >
                Selected tab
              </span>
            </div>
          </div>
        </div>

        <div>
          <ColorField id="b-color" label="Theme colour" value={color} onChange={setColor} />
          <Button
            variant="dark"
            style={{ marginTop: 12 }}
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
    </>
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
      <span className="field-label">{label}</span>
      <div className="upload">
        <div className="upload-box">{url ? <img src={url} alt="" /> : <ImageUp size={20} />}</div>
        <div className="row" style={{ gap: 8 }}>
          <input
            ref={input}
            type="file"
            accept="image/png,image/jpeg,image/webp,image/svg+xml,image/x-icon,.ico"
            hidden
            onChange={(e) => {
              const file = e.target.files?.[0]
              e.target.value = ''
              if (!file) return
              if (file.size > MAX_BYTES) return onError(`${label} must be 2 MB or smaller.`)
              onPick(file)
            }}
          />
          <Button variant="outline" size="sm" onClick={() => input.current?.click()} disabled={disabled}>
            <ImageUp /> {busy ? 'Uploading…' : url ? 'Replace' : 'Upload'}
          </Button>
          {url && (
            <Button variant="ghost" size="sm" onClick={onRemove} disabled={disabled} className="danger-text">
              <Trash2 /> Remove
            </Button>
          )}
        </div>
      </div>
      <Hint>{hint}</Hint>
    </div>
  )
}
