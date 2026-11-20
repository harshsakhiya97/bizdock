-- AI Insights: the AI button on every page (summary of the screen and a chat about it, through the workspace's Gemini
-- connection). Permission ai_insights.view (Access control); the edge function gemini asks ai_insights_me() who is
-- asking. The Gemini connection keeps price_in / price_out (₹ per 1M tokens) and monthly_limit (₹) in its config.

-- the caller's team member id when they may use AI Insights in this workspace (else null)
create or replace function public.ai_insights_me(p_tenant uuid) returns uuid
language sql stable security definer set search_path = '' as $$
  select case when private.has_permission(p_tenant, 'ai_insights', 'view') then coalesce(private.my_member_id(p_tenant), '00000000-0000-0000-0000-000000000000'::uuid) end
$$;
revoke all on function public.ai_insights_me(uuid) from public, anon;
grant execute on function public.ai_insights_me(uuid) to authenticated;
