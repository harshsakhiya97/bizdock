import { useEffect, type RefObject } from 'react'

export function useClickOutside(ref: RefObject<HTMLElement | null>, active: boolean, onOutside: () => void) {
  useEffect(() => {
    if (!active) return
    const onClick = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) onOutside()
    }
    document.addEventListener('mousedown', onClick)
    return () => document.removeEventListener('mousedown', onClick)
  }, [ref, active, onOutside])
}
