export type Release = {
  version: string
  /** ISO date, e.g. 2026-10-08 */
  date: string
  title: string
  summary?: string
  new?: string[]
  improved?: string[]
  fixed?: string[]
  removed?: string[]
}

// Newest first. The first entry is shown as "Current".
export const releases: Release[] = [
  {
    version: '0.2',
    date: '2026-10-12',
    title: 'Clients, their workspaces and every module behind them',
    summary: 'Set up clients and power their CRM workspaces.',
    new: [
      'Clients: add, edit and remove clients, each with their own web addresses, logo, colours and app name.',
      'Businesses and branches for each client, with optional GST details.',
      'Roles and team: role levels and ready-made access presets for each client’s team.',
      'The data behind each client’s workspace: funnels, leads, follow-ups, customers, sales, collections, payments, calendar and attendance, each with rules for who can see what.',
    ],
    improved: [
      'The Muzic Lover look across the app, keeping BizDock’s colours and logo.',
      'Forms: tighter spacing, and drawers that scroll to the end.',
    ],
    fixed: [
      'The logout box no longer shows behind the page.',
      'Dropdowns inside cards are no longer cut off.',
      'The page no longer slides sideways when you scroll on a trackpad.',
    ],
    removed: ['Plans are hidden from client screens for now.'],
  },
  {
    version: '0.1',
    date: '2026-10-08',
    title: 'Login, Dashboard, Profile and What’s New',
    summary: 'The first version of BizDock.',
    new: [
      'Login with email and password, plus “Forgot Password?” to get a reset link by email.',
      'Dashboard with a welcome message and stat cards for Leads, Follow-ups, Payments and Profit (numbers come later).',
      'My Profile: see your name, email, phone and role, edit your name and phone, and reset your password.',
      'What’s New: this page, listing every version and what it added.',
    ],
  },
]
