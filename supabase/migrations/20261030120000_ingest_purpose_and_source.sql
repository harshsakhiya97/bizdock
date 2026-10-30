-- Webhook / sheet / import leads: Purpose goes into the lead's Purpose (it was only kept as an extra field),
-- and a field mapped to "Lead source" sets the lead's Source by name (added to the Sources list when new;
-- otherwise utm_source, then the default as before). An existing lead keeps its Source unless it has none.
do $$
declare src text; n int;
begin
  src := pg_get_functiondef('private.ingest_lead(uuid,uuid,uuid,uuid,jsonb,text,boolean,uuid)'::regprocedure);

  src := replace(src,
    $a$  nt       text := nullif(trim(coalesce(d ->> 'note', '')), '');$a$,
    $b$  nt       text := nullif(trim(coalesce(d ->> 'note', '')), '');
  pu       text := nullif(trim(coalesce(d ->> 'purpose', '')), '');
  sname    text := nullif(trim(coalesce(d ->> 'lead_source', '')), '');$b$);

  src := replace(src,
    $a$where k not in ('name', 'first_name', 'last_name', 'phone', 'email', 'city', 'note', 'tags',$a$,
    $b$where k not in ('name', 'first_name', 'last_name', 'phone', 'email', 'city', 'note', 'tags', 'purpose', 'lead_source',$b$);

  -- the source: the mapped "Lead source" field (by name, added when new), then utm_source, then the default
  src := replace(src,
    $a$    select id into src from public.lead_sources
    where tenant_id = f.tenant_id and is_active and lower(name) = lower(coalesce(u ->> 'utm_source', ''));
    if src is null then$a$,
    $b$    if sname is not null then
      select id into src from public.lead_sources where tenant_id = f.tenant_id and lower(name) = lower(sname) limit 1;
      if src is null then
        insert into public.lead_sources (tenant_id, name, sort_order)
        values (f.tenant_id, sname, coalesce((select max(sort_order) + 1 from public.lead_sources where tenant_id = f.tenant_id), 1))
        on conflict (tenant_id, name) do nothing
        returning id into src;
        if src is null then select id into src from public.lead_sources where tenant_id = f.tenant_id and name = sname; end if;
      end if;
    end if;
    if src is null then
      select id into src from public.lead_sources
      where tenant_id = f.tenant_id and is_active and lower(name) = lower(coalesce(u ->> 'utm_source', ''));
    end if;
    if src is null then$b$);

  src := replace(src,
    $a$                              extra, notes, created_by)$a$,
    $b$                              extra, notes, created_by, purpose)$b$);
  src := replace(src,
    $a$            v_extra, nt, p_actor)
    returning id into lid;$a$,
    $b$            v_extra, nt, p_actor, pu)
    returning id into lid;$b$);

  src := replace(src,
    $a$      city         = coalesce(ct, l.city),$a$,
    $b$      city         = coalesce(ct, l.city),
      purpose      = coalesce(pu, l.purpose),
      source_id    = coalesce(l.source_id, (select s.id from public.lead_sources s where s.tenant_id = f.tenant_id and lower(s.name) = lower(sname) limit 1)),$b$);

  -- every piece must have been found
  n := (length(src) - length(replace(src, 'pu       text', ''))) / length('pu       text')
     + (length(src) - length(replace(src, '''purpose'', ''lead_source''', ''))) / length('''purpose'', ''lead_source''')
     + (length(src) - length(replace(src, 'if sname is not null then', ''))) / length('if sname is not null then')
     + (length(src) - length(replace(src, 'created_by, purpose)', ''))) / length('created_by, purpose)')
     + (length(src) - length(replace(src, 'p_actor, pu)', ''))) / length('p_actor, pu)')
     + (length(src) - length(replace(src, 'purpose      = coalesce(pu, l.purpose)', ''))) / length('purpose      = coalesce(pu, l.purpose)');
  if n <> 6 then raise exception 'ingest_lead: % of 6 changes applied', n; end if;
  execute src;
end $$;
