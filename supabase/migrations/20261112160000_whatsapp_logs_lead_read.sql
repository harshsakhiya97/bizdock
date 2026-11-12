-- A lead's WhatsApp (WATI) messages are readable by whoever can see that lead (the lead page's WhatsApp tab).
drop policy if exists "whatsapp_logs: lead read" on public.whatsapp_logs;
create policy "whatsapp_logs: lead read" on public.whatsapp_logs for select to authenticated
  using (lead_id is not null and exists (select 1 from public.leads l where l.id = lead_id));
create index if not exists whatsapp_logs_lead on public.whatsapp_logs (lead_id, sent_at desc);
