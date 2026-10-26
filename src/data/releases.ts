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
    version: '0.6',
    date: '2026-10-26',
    title: 'Paid Podcast flow',
    summary: 'Database changes for the Paid Podcast flow.',
    new: [
      'meetings table (lead, date, time, mode, link / location, status, outcome note, reschedule history) with RLS on the meetings permission; Not qualified moves the lead to its funnel’s Lost stage.',
      'Shared studio: Studio Rental and Paid Podcast bookings (not cancelled) can’t overlap; studio_busy() lists the studio’s bookings (slot only) for both calendars.',
    ],
  },
  {
    version: '0.5',
    date: '2026-10-26',
    title: 'Studio rental flow completed',
    summary: 'Database changes for the Studio Rental flow.',
    new: [
      'Funnel lead owner: funnels.assign_mode (none / single / round_robin), assign_members and assign_cursor; a trigger gives new funnel leads without an owner their owner, skipping inactive members.',
      'Workflow runner: WhatsApp to a custom number; purpose and the lead\'s extra fields as message variables.',
    ],
  },
  {
    version: '0.4',
    date: '2026-10-23',
    title: 'Sub-business access and the data behind services and payment plans',
    summary: 'Database changes for the client feedback release.',
    new: [
      'Services on bookings (booking_items) and payment plans: booking_payments with label, due date and Pending / Paid status; only paid parts count as received.',
      'Invoice number given when a booking is created (per business, INV/26-27/0001).',
      'Sub-business access per team member (member_businesses.sub_business_ids), enforced on leads, bookings, their items and payments, and funnels.',
      'Workflow runner: workflow_runs table, form submissions start runs, workflow-runner function (every minute + right after a submission) sends WATI templates and handles Wait steps.',
      'Workflow test run: workflow_test_run() starts a run with typed-in details (workflow_runs.is_test, test_data).',
      'businesses.has_sub_businesses and businesses.type (a business without sub-businesses has a type of its own).',
    ],
  },
  {
    version: '0.3',
    date: '2026-10-21',
    title: 'Connections per client and the Podcast Studio flow',
    summary: 'Choose which outside services each client can connect, and the data behind their new Podcast Studio flow.',
    new: [
      'Connections for each client: allow WhatsApp and pick its provider (WATI, Dovesoft, AiSensy, Meta), and allow Facebook Ads, Callyzer, Zoom, Voice Call and Perisclaw.',
      'Sub-businesses for each business, with leads, funnels and bookings linked to them.',
      'Funnel webhooks, Google Sheet sync every minute and the WhatsApp templates connection behind each client’s workspace.',
    ],
    improved: [
      'Booking invoices are numbered per business when there is no billing company.',
    ],
  },
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
