-- every id WATI uses for a sent message (its id, whatsappMessageId (wamid), localMessageId): delivered / read events are matched on them
alter table public.whatsapp_logs add column wati_ids text[] not null default '{}';
create index whatsapp_logs_wati_ids on public.whatsapp_logs using gin (wati_ids);
