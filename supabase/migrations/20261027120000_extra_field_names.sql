-- A form field kept as an extra field can be saved under a name of its own: field_map value "extra:<name>".
create or replace function private.map_lead_fields(d jsonb, fmap jsonb)
returns jsonb language plpgsql immutable set search_path = '' as $$
declare
  k text;
  v text;
  target text;
  outp jsonb := '{}';
begin
  for k, v in select key, value #>> '{}' from jsonb_each(coalesce(d, '{}')) loop
    if coalesce(trim(v), '') = '' then continue; end if;
    target := coalesce(fmap ->> k, case
      when k in ('name', 'full_name', 'fullname', 'your_name', 'customer_name', 'lead_name') then 'name'
      when k in ('first_name', 'firstname', 'fname', 'given_name') then 'first_name'
      when k in ('last_name', 'lastname', 'lname', 'surname', 'family_name') then 'last_name'
      when k in ('phone', 'contact', 'contact_no', 'contact_number', 'mobile', 'mobileno', 'mobile_no', 'mobile_number',
                 'phone_no', 'phone_number', 'whatsapp', 'whatsapp_no', 'whatsapp_number', 'number') then 'phone'
      when k in ('email', 'email_id', 'emailid', 'email_address', 'mail', 'e_mail') then 'email'
      when k in ('city', 'town', 'location') then 'city'
      when k in ('company', 'company_name', 'business', 'business_name', 'organization', 'organisation', 'firm') then 'company_name'
      when k in ('purpose', 'reason', 'requirement', 'interest', 'interested_in', 'service') then 'purpose'
      when k in ('note', 'notes', 'remark', 'remarks', 'message', 'comment', 'comments', 'query') then 'note'
      when k like 'utm\_%' then k
      else 'extra' end);
    if target = 'ignore' then continue; end if;
    if target = 'extra' then target := k;
    elsif target like 'extra:%' then target := coalesce(nullif(trim(substr(target, 7)), ''), k);
    end if;
    if not (outp ? target) then outp := outp || jsonb_build_object(target, trim(v)); end if;
  end loop;
  return outp;
end $$;
