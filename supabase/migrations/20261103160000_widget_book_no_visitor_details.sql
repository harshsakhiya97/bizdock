-- Booking Calendar: no "Your information" step, so a booking has only the slot (name / phone / email optional).
alter table public.widget_bookings alter column name drop not null, alter column phone drop not null, alter column email drop not null;
-- widget_book: same as before, without the name / phone / email checks (empty ones are saved as null)
create or replace function public.widget_book(p_code text, p_start timestamptz, p_name text, p_phone text, p_email text)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $$
declare
  w public.widgets; v_slot record; v_members uuid[]; v_n int; v_at int; v_pick uuid; v_id uuid; v_end timestamptz;
  v_member jsonb := null;
begin
  select * into w from public.widgets x where x.code = p_code and x.is_active and x.archived_at is null;
  if w.id is null then raise exception 'This booking calendar isn''t available any more.'; end if;
  -- one booking at a time per widget
  perform pg_advisory_xact_lock(hashtextextended(w.id::text, 0));
  select * into v_slot from public.widget_slots(p_code, (p_start at time zone 'Asia/Kolkata')::date, (p_start at time zone 'Asia/Kolkata')::date) s
   where s.starts_at = p_start;
  if v_slot.starts_at is null then raise exception 'This time can''t be booked. Please pick another.'; end if;
  if v_slot.total > 0 and v_slot.free = 0 then raise exception 'This time was just booked. Please pick another.'; end if;
  v_end := v_slot.ends_at;
  v_members := private.widget_members(w);
  v_n := coalesce(array_length(v_members, 1), 0);
  if v_n > 0 then
    -- round robin: the next free member after the one who got the last booking
    v_at := coalesce(array_position(v_members, w.last_member_id), 0);
    for k in 1..v_n loop
      if not private.member_busy(w.tenant_id, v_members[((v_at + k - 1) % v_n) + 1], p_start, v_end) then
        v_pick := v_members[((v_at + k - 1) % v_n) + 1];
        exit;
      end if;
    end loop;
    if v_pick is null then raise exception 'This time was just booked. Please pick another.'; end if;
    update public.widgets set last_member_id = v_pick where id = w.id;
    select jsonb_build_object('id', m.id, 'name', coalesce(p.full_name, ''), 'email', coalesce(p.email, ''), 'phone', coalesce(p.phone, ''))
      into v_member
      from public.tenant_members m left join public.profiles p on p.id = m.user_id where m.id = v_pick;
  end if;
  insert into public.widget_bookings (tenant_id, widget_id, starts_at, ends_at, member_id, name, phone, email)
  values (w.tenant_id, w.id, p_start, v_end, v_pick, nullif(trim(coalesce(p_name, '')), ''), nullif(trim(coalesce(p_phone, '')), ''), nullif(lower(trim(coalesce(p_email, ''))), ''))
  returning id into v_id;
  return jsonb_build_object(
    'booking_id', v_id, 'tenant_id', w.tenant_id, 'widget_id', w.id, 'widget_name', w.name,
    'starts_at', p_start, 'ends_at', v_end, 'member', v_member,
    'webhook', w.config -> 'webhook', 'thank_you', w.config -> 'thank_you', 'redirect_url', w.config -> 'redirect_url'
  );
end $$;

revoke all on function public.widget_book(text, timestamptz, text, text, text) from public, anon, authenticated;
grant execute on function public.widget_book(text, timestamptz, text, text, text) to service_role;
