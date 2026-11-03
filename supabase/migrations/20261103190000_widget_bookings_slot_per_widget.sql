-- One booking per member and start time within a widget (a deleted widget's old holds no longer block the slot).
drop index if exists public.widget_bookings_member_slot;
create unique index widget_bookings_member_slot on public.widget_bookings (widget_id, member_id, starts_at) where status = 'booked' and member_id is not null;
