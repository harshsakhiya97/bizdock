-- WhatsApp template header files (sample image / video / document): a public bucket, one folder per workspace,
-- uploaded by whoever can edit System Connections. WhatsApp limits: image 5 MB, video 16 MB.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('wa-media', 'wa-media', true, 16777216,
        array['image/jpeg', 'image/png', 'video/mp4', 'video/3gpp', 'application/pdf'])
on conflict (id) do nothing;

create policy "wa-media: insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'wa-media' and private.has_permission(((storage.foldername(name))[1])::uuid, 'settings', 'edit'));
create policy "wa-media: update" on storage.objects for update to authenticated
  using (bucket_id = 'wa-media' and private.has_permission(((storage.foldername(name))[1])::uuid, 'settings', 'edit'));
create policy "wa-media: delete" on storage.objects for delete to authenticated
  using (bucket_id = 'wa-media' and private.has_permission(((storage.foldername(name))[1])::uuid, 'settings', 'edit'));
