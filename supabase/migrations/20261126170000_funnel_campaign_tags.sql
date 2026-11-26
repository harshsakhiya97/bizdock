-- Funnel → Facebook Ads / Google Ads: campaigns join a funnel by tags. Any campaign (any ad account) whose name
-- contains one of the funnel's tags (case ignored) is linked to it — when the tags are saved and whenever a campaign
-- comes in or is renamed by a sync. A campaign stays in the first funnel it joined. Links made before stay.
alter table public.funnels add column if not exists meta_tags text[] not null default '{}';
alter table public.funnels add column if not exists google_tags text[] not null default '{}';

create or replace function private.tag_hit(p_name text, p_tags text[]) returns text
language sql immutable set search_path = '' as $$
  select t from unnest(p_tags) t
   where trim(t) <> '' and position(lower(trim(t)) in lower(coalesce(p_name, ''))) > 0
   limit 1
$$;

-- link every not-yet-linked campaign of the workspace whose name matches a funnel's tags (oldest funnel first)
create or replace function private.link_campaigns_by_tags(p_tenant uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.funnel_ad_links (tenant_id, funnel_id, campaign_id, adset_id)
  select p_tenant, x.funnel_id, x.campaign_id, null
    from (
      select distinct on (c.campaign_id) c.campaign_id, f.id as funnel_id
        from public.meta_campaigns c
        join public.funnels f on f.tenant_id = c.tenant_id and cardinality(f.meta_tags) > 0
       where c.tenant_id = p_tenant and private.tag_hit(c.name, f.meta_tags) is not null
         and not exists (select 1 from public.funnel_ad_links l where l.tenant_id = p_tenant and l.campaign_id = c.campaign_id)
       order by c.campaign_id, f.created_at
    ) x
  on conflict do nothing;

  insert into public.funnel_google_links (tenant_id, funnel_id, campaign_id)
  select p_tenant, x.funnel_id, x.campaign_id
    from (
      select distinct on (c.campaign_id) c.campaign_id, f.id as funnel_id
        from public.google_campaigns c
        join public.funnels f on f.tenant_id = c.tenant_id and cardinality(f.google_tags) > 0
       where c.tenant_id = p_tenant and private.tag_hit(c.name, f.google_tags) is not null
         and not exists (select 1 from public.funnel_google_links l where l.tenant_id = p_tenant and l.campaign_id = c.campaign_id)
       order by c.campaign_id, f.created_at
    ) x
  on conflict do nothing;
end $$;

-- tags saved on a funnel → link now
create or replace function private.funnel_tags_changed() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform private.link_campaigns_by_tags(new.tenant_id);
  return null;
end $$;
drop trigger if exists funnel_tags_link on public.funnels;
create trigger funnel_tags_link after insert or update of meta_tags, google_tags on public.funnels
  for each row execute function private.funnel_tags_changed();

-- a campaign brought in (or renamed) by a sync → link it if a funnel's tags match
create or replace function private.campaign_tag_link() returns trigger
language plpgsql security definer set search_path = '' as $$
declare f uuid;
begin
  if tg_op = 'UPDATE' and new.name is not distinct from old.name then return null; end if;
  if tg_table_name = 'meta_campaigns' then
    if exists (select 1 from public.funnel_ad_links l where l.tenant_id = new.tenant_id and l.campaign_id = new.campaign_id) then return null; end if;
    select x.id into f from public.funnels x where x.tenant_id = new.tenant_id and cardinality(x.meta_tags) > 0
       and private.tag_hit(new.name, x.meta_tags) is not null order by x.created_at limit 1;
    if f is not null then
      insert into public.funnel_ad_links (tenant_id, funnel_id, campaign_id, adset_id) values (new.tenant_id, f, new.campaign_id, null) on conflict do nothing;
    end if;
  else
    if exists (select 1 from public.funnel_google_links l where l.tenant_id = new.tenant_id and l.campaign_id = new.campaign_id) then return null; end if;
    select x.id into f from public.funnels x where x.tenant_id = new.tenant_id and cardinality(x.google_tags) > 0
       and private.tag_hit(new.name, x.google_tags) is not null order by x.created_at limit 1;
    if f is not null then
      insert into public.funnel_google_links (tenant_id, funnel_id, campaign_id) values (new.tenant_id, f, new.campaign_id) on conflict do nothing;
    end if;
  end if;
  return null;
end $$;
drop trigger if exists meta_campaign_tag_link on public.meta_campaigns;
create trigger meta_campaign_tag_link after insert or update of name on public.meta_campaigns
  for each row execute function private.campaign_tag_link();
drop trigger if exists google_campaign_tag_link on public.google_campaigns;
create trigger google_campaign_tag_link after insert or update of name on public.google_campaigns
  for each row execute function private.campaign_tag_link();

-- Pride: starting tags (the campaigns linked today all carry them)
update public.funnels set meta_tags = array['VSL'], google_tags = array['VSL']
 where id = '500a4194-87f4-4b55-98c9-df9ce387335e' and cardinality(meta_tags) = 0;
update public.funnels set meta_tags = array['Studio Visit'], google_tags = array['Studio Visit']
 where id = 'cdeb2fe1-9d88-4251-9828-129bc256f6bb' and cardinality(meta_tags) = 0;
update public.funnels set meta_tags = array['₹30,000 Podcast Host'], google_tags = array['₹30,000 Podcast Host']
 where id = '9dd71e8c-988e-4165-8f8e-088191701791' and cardinality(meta_tags) = 0;
