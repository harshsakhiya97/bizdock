import { useState, type FormEvent } from 'react'
import { Database } from 'lucide-react'
import { Button } from '@/components/Button'
import { Hint, Label, TextInput } from '@/components/Field'
import { cn } from '@/lib/cn'
import { updateTenant } from '../api'
import { SaveStatus, SectionHeader, type SectionProps } from './shared'

export function DatabaseSection({ tenant, onSaved }: SectionProps) {
  const [own, setOwn] = useState(!!tenant.supabase_url)
  const [url, setUrl] = useState(tenant.supabase_url ?? '')
  const [key, setKey] = useState(tenant.supabase_key ?? '')
  const [error, setError] = useState<string | null>(null)
  const [saved, setSaved] = useState(false)
  const [busy, setBusy] = useState(false)

  async function onSubmit(e: FormEvent) {
    e.preventDefault()
    setSaved(false)
    const u = url.trim().replace(/\/+$/, '')
    const k = key.trim()
    if (own) {
      if (!/^https:\/\/[a-z0-9-]+\.supabase\.co$/.test(u))
        return setError('Enter a URL like https://abcd1234.supabase.co')
      if (!k) return setError('Enter the project’s publishable (anon) key.')
    }
    setBusy(true)
    setError(null)
    try {
      onSaved(
        await updateTenant(
          tenant.id,
          own ? { supabase_url: u, supabase_key: k } : { supabase_url: null, supabase_key: null },
        ),
      )
      setSaved(true)
    } catch (err) {
      setError((err as Error).message)
    } finally {
      setBusy(false)
    }
  }

  return (
    <>
      <SectionHeader title="Database" description="Where this client's data lives." />

      <form onSubmit={onSubmit} className="stack" style={{ maxWidth: 560 }}>
        <div className="choice-grid">
          {[
            { value: false, title: 'Shared BizDock database', text: 'Default. Data is kept apart by security rules.' },
            { value: true, title: 'Own Supabase project', text: 'The client’s panel connects to a separate project.' },
          ].map((o) => (
            <button
              key={String(o.value)}
              type="button"
              onClick={() => {
                setOwn(o.value)
                setSaved(false)
              }}
              className={cn('choice', own === o.value && 'is-active')}
            >
              <b>
                <Database size={15} /> {o.title}
              </b>
              <small>{o.text}</small>
            </button>
          ))}
        </div>

        {own && (
          <>
            <div>
              <Label htmlFor="db-url" required>
                Supabase URL
              </Label>
              <TextInput
                id="db-url"
                placeholder="https://abcd1234.supabase.co"
                value={url}
                onChange={(e) => setUrl(e.target.value)}
              />
            </div>
            <div>
              <Label htmlFor="db-key" required>
                Publishable (anon) key
              </Label>
              <TextInput
                id="db-key"
                placeholder="sb_publishable_…"
                value={key}
                onChange={(e) => setKey(e.target.value)}
                className="input-mono"
              />
              <Hint>Only the public key. Never paste a secret or service-role key here.</Hint>
            </div>
            <div className="alert alert-warning">
              Switching moves where the client&apos;s panel reads and writes. The other project must already have the
              same tables and the client&apos;s users; data isn&apos;t copied automatically.
            </div>
          </>
        )}

        <SaveStatus error={error} saved={saved} />
        <div>
          <Button type="submit" variant="dark" disabled={busy}>
            {busy ? 'Saving…' : 'Save database setting'}
          </Button>
        </div>
      </form>
    </>
  )
}
