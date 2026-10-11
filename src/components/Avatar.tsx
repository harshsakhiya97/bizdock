const initials = (name = '') =>
  name
    .split(/[\s@._-]+/)
    .filter(Boolean)
    .slice(0, 2)
    .map((w) => w[0].toUpperCase())
    .join('')

export function Avatar({ name, size = 32 }: { name: string; size?: number }) {
  return (
    <div className="avatar" style={{ width: size, height: size, fontSize: size * 0.36 }}>
      {initials(name)}
    </div>
  )
}
