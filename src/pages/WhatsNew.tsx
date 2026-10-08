import { Sparkles } from 'lucide-react'
import { releases } from '@/data/releases'
import { cn } from '@/lib/cn'

export function WhatsNewPage() {
  return (
    <div>
      <h2 className="text-lg font-semibold">What&apos;s New</h2>
      <p className="mt-0.5 text-sm text-gray-600">Every version of the BizDock app and what it added.</p>

      <ol className="relative mt-5 max-w-[940px] space-y-6 pl-[34px]">
        <span aria-hidden className="absolute top-2 bottom-0 left-[9px] w-px bg-gray-200" />
        {releases.map((r, i) => {
          const current = i === 0
          return (
            <li key={r.version} className="relative">
              <span
                aria-hidden
                className={cn(
                  'absolute top-6 -left-[31px] size-3 rounded-full ring-4 ring-white',
                  current ? 'bg-brand' : 'bg-gray-300',
                )}
              />
              <article className="rounded-xl border border-gray-200 bg-white p-6">
                <div className="flex flex-wrap items-center gap-2.5">
                  <span className={cn('text-[17px] font-bold', current ? 'text-brand' : 'text-gray-900')}>
                    Version {r.version}
                  </span>
                  {current && (
                    <span className="rounded-md bg-emerald-50 px-2 py-0.5 text-xs font-medium text-emerald-700">
                      Current
                    </span>
                  )}
                  <span className="text-sm text-gray-500">{r.date}</span>
                </div>
                <h3 className="mt-2 text-xl font-bold tracking-tight">{r.title}</h3>
                <p className="mt-2 text-[15px] text-gray-600">{r.summary}</p>

                <span className="mt-4 inline-flex items-center gap-1.5 rounded-md bg-blue-50 px-2 py-1 text-sm font-medium text-blue-600">
                  <Sparkles className="size-3.5" /> New
                </span>
                <ul className="mt-2.5 list-disc space-y-2 pl-5 text-[15px] leading-relaxed text-gray-800 marker:text-gray-800">
                  {r.added.map((item) => (
                    <li key={item}>{item}</li>
                  ))}
                </ul>
              </article>
            </li>
          )
        })}
      </ol>
    </div>
  )
}
