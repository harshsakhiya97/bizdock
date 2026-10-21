-- sheet_ingest / webhook_submit: "missing fields" list built with array_append (text[] || 'x' was read as an array literal);
-- sheet columns like "Full Name" / "WhatsApp Number" are matched like full_name / whatsapp_number unless mapped by hand.
do $$
declare
  d text;
  f text;
begin
  foreach f in array array['public.sheet_ingest(uuid,jsonb,int)', 'public.webhook_submit(text,jsonb)'] loop
    d := pg_get_functiondef(f::regprocedure);
    d := replace(d, 'miss := miss || ''name'';', 'miss := array_append(miss, ''name'');');
    d := replace(d, 'miss := miss || ''email'';', 'miss := array_append(miss, ''email'');');
    d := replace(d, 'miss := miss || ''phone'';', 'miss := array_append(miss, ''phone'');');
    if position('array_append(miss, ''phone'')' in d) = 0 then raise exception 'patch did not apply to %', f; end if;
    if f like 'public.sheet_ingest%' then
      if position('d := private.map_lead_fields(r, s.field_map);' in d) = 0 then raise exception 'sheet_ingest map patch'; end if;
      d := replace(d, 'd := private.map_lead_fields(r, s.field_map);',
        'd := private.map_lead_fields((select coalesce(jsonb_object_agg(case when s.field_map ? e.key then e.key
                 else trim(both ''_'' from lower(regexp_replace(trim(e.key), ''[^a-zA-Z0-9]+'', ''_'', ''g''))) end, e.value), ''{}'')
             from jsonb_each(r) e), s.field_map);');
    end if;
    execute d;
  end loop;
end $$;
