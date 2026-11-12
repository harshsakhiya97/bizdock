-- Leads list (Paid Podcast, like the old CRM): per lead its last comment, follow-ups done, connected calls,
-- the pending follow-up and the latest meeting. Runs as the caller, so each table's own access rules apply.
create or replace function public.lead_list_extras(p_tenant uuid, p_sub uuid)
returns table (
  lead_id uuid,
  last_note text,
  last_note_at timestamptz,
  fu_done int,
  connected int,
  pending_fu_id uuid,
  meeting_status text,
  meeting_link text,
  meeting_date date,
  meeting_time time
)
language sql stable security invoker set search_path = '' as $$
  select l.id,
         n.note, n.created_at,
         coalesce(f.done, 0)::int, coalesce(c.connected, 0)::int, f.pending_id,
         m.status, m.link, m.meeting_date, m.start_time
    from public.leads l
    left join lateral (
      select a.note, a.created_at from public.lead_activities a
       where a.lead_id = l.id and a.kind = 'note' and coalesce(a.note, '') <> ''
       order by a.created_at desc limit 1) n on true
    left join lateral (
      select count(*) filter (where fu.status = 'done') as done,
             (array_agg(fu.id order by fu.due_at) filter (where fu.status = 'pending'))[1] as pending_id
        from public.follow_ups fu where fu.lead_id = l.id) f on true
    left join lateral (
      select count(*) as connected from public.calls k where k.lead_id = l.id and coalesce(k.duration_sec, 0) > 0) c on true
    left join lateral (
      select mt.status, mt.link, mt.meeting_date, mt.start_time from public.meetings mt
       where mt.lead_id = l.id order by mt.meeting_date desc, mt.start_time desc limit 1) m on true
   where l.tenant_id = p_tenant and l.sub_business_id = p_sub;
$$;
revoke all on function public.lead_list_extras(uuid, uuid) from public, anon;
grant execute on function public.lead_list_extras(uuid, uuid) to authenticated;
