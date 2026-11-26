-- WhatsApp → Individual chat: the chat list, 20 at a time (Show more), searched on the server.
-- One row per number: its newest message, the lead's name (from any of its messages) and replies. Who may see a message
-- is checked once (as the whatsapp_logs read rules: Settings edit / WhatsApp scope / the leads the person can see),
-- not per message.
create or replace function public.wa_chat_list(p_tenant uuid, p_from date, p_to date, p_q text default null,
                                               p_offset integer default 0, p_limit integer default 20)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_all boolean := private.is_platform_owner() or private.has_permission(p_tenant, 'settings', 'edit')
                   or private.area_scope(p_tenant, 'whatsapp') = 'all';
  v_scope text;
  v_biz uuid[];
  v_subs uuid[];
  v_team uuid[];
  v_me uuid;
  v_phs text[] := '{}';
  v_q text := lower(trim(coalesce(p_q, '')));
  v_digits text := regexp_replace(coalesce(p_q, ''), '\D', '', 'g');
  v_rows jsonb;
begin
  if not v_all then
    if not private.is_member(p_tenant) then return '[]'; end if;
    -- the numbers of the leads this person can see (same as the leads list)
    v_scope := coalesce(private.lead_scope(p_tenant), 'none');
    if v_scope <> 'none' then
      select coalesce(array_agg(b.id), '{}') into v_biz from public.businesses b
       where b.tenant_id = p_tenant and private.can_access_business(b.id);
      select coalesce(array_agg(s.id), '{}') into v_subs from public.sub_businesses s
       where s.business_id = any (v_biz) and private.can_access_sub(s.business_id, s.id);
      v_me := private.my_member_id(p_tenant);
      if v_scope = 'team' then select coalesce(array_agg(x), '{}') into v_team from private.my_team(p_tenant) x; end if;
      select coalesce(array_agg(distinct private.ph10(l.phone)), '{}') into v_phs
        from public.leads l
       where l.tenant_id = p_tenant and coalesce(l.phone, '') <> ''
         and l.business_id = any (v_biz)
         and (l.sub_business_id is null or l.sub_business_id = any (v_subs))
         and case v_scope when 'all' then true
               when 'team' then l.owner_id is null or l.owner_id = any (v_team)
               when 'own' then l.owner_id = v_me else false end;
    end if;
  end if;

  with w as (
    select w.id, w.direction, w.phone, w.lead_id, w.template, w.body, w.source, w.workflow_id, w.status, w.error,
           w.sent_at, w.delivered_at, w.read_at
      from public.whatsapp_logs w
     where w.tenant_id = p_tenant
       and (p_from is null or w.sent_at >= (p_from::timestamp at time zone 'Asia/Kolkata'))
       and (p_to is null or w.sent_at < ((p_to + 1)::timestamp at time zone 'Asia/Kolkata'))
       and (v_all or private.ph10(w.phone) = any (v_phs) or private.can_see_wa(p_tenant, w.phone, w.sent_by))
  ), c as (
    select w.phone,
           (array_agg(row_to_json(w)::jsonb order by w.sent_at desc))[1] as last,
           max(w.sent_at) as last_at,
           count(*) filter (where w.direction = 'in') as replies,
           (array_agg(w.lead_id order by w.sent_at desc) filter (where w.lead_id is not null))[1] as lead_id
      from w group by w.phone
  ), n as (
    select c.*, trim(concat_ws(' ', l.first_name, l.last_name)) as name
      from c left join public.leads l on l.id = c.lead_id
  )
  select coalesce(jsonb_agg(jsonb_build_object('phone', x.phone, 'name', coalesce(x.name, ''), 'last', x.last, 'replies', x.replies)
                            order by x.last_at desc), '[]')
    into v_rows
    from (
      select * from n
       where v_q = '' or lower(coalesce(n.name, '')) like '%' || v_q || '%' or (length(v_digits) >= 1 and n.phone like '%' || v_digits || '%')
       order by n.last_at desc
       offset greatest(p_offset, 0) limit least(greatest(p_limit, 1), 200)
    ) x;
  return v_rows;
end $$;
revoke all on function public.wa_chat_list(uuid, date, date, text, integer, integer) from public, anon;
grant execute on function public.wa_chat_list(uuid, date, date, text, integer, integer) to authenticated;
