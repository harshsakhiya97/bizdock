export type Release = {
  version: string
  date: string
  title: string
  summary: string
  added: string[]
}

// Newest first. The first entry is shown as "Current".
export const releases: Release[] = [
  {
    version: '1.0',
    date: '8 October 2026',
    title: 'Login, Dashboard, Profile and What’s New',
    summary: 'The first version of BizDock.',
    added: [
      'Login with email and password, plus “Forgot Password?” to get a reset link by email.',
      'Dashboard with a welcome message and stat cards for Leads, Follow-ups, Payments and Profit (numbers come later).',
      'My Profile: see your name, email, phone and role, edit your name and phone, and reset your password.',
      'What’s New: this page, listing every version and what it added.',
    ],
  },
]
