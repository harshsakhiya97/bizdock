-- Fix: the keep-the-keys trigger (20261123110000) ran as the caller, and the server (service role) can't use schema
-- private — so every server-side update of a connection's config failed (403) since then: Razorpay's sync status /
-- last sync, Callyzer, Meta, Gemini / Claude key checks… It now runs as its owner, like the other triggers.
alter function private.integrations_keep_keys() security definer;
