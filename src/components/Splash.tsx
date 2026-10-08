import { LogoMark } from './Logo'

export function Splash() {
  return (
    <div className="grid min-h-svh place-items-center bg-canvas">
      <LogoMark size={64} className="animate-pulse shadow-sm" />
    </div>
  )
}
