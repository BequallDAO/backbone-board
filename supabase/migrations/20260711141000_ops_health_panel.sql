-- Backbone BLD-207 - live ops-health panel for the board.
-- All values are read from Backbone/Supabase counters. No manual rows.

create or replace function _ops_health_panel(p_agent_key text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_expired int := 0;
begin
  perform _auth_agent(p_agent_key);
  v_expired := _write_queue_expire_leases();

  return jsonb_build_object(
    'generated_at', now(),
    'zero_manual_elements', true,
    'source_tables', jsonb_build_array(
      'write_queue_items',
      'write_queue_exceptions',
      'workspace_rate_limit_buckets',
      'events',
      'app_config'
    ),
    'queue', jsonb_build_object(
      'expired_leases_requeued', v_expired,
      'depth_by_status', coalesce((
        select jsonb_object_agg(status, n)
        from (
          select status, count(*)::int as n
          from write_queue_items
          group by status
        ) s
      ), '{}'::jsonb),
      'queue_depth_active', coalesce((
        select count(*)::int
        from write_queue_items
        where status in ('queued', 'leased')
      ), 0),
      'queue_depth_dead_letter', coalesce((
        select count(*)::int
        from write_queue_items
        where status = 'dead_letter'
      ), 0),
      'oldest_stuck_write', coalesce((
        select jsonb_build_object(
          'id', id,
          'queue_name', queue_name,
          'status', status,
          'age_minutes', round(extract(epoch from now() - created_at) / 60.0, 1),
          'retry_count', retry_count,
          'max_retries', max_retries,
          'leased_by', leased_by,
          'lease_expires_at', lease_expires_at,
          'last_error', last_error
        )
        from write_queue_items
        where status in ('queued', 'leased', 'dead_letter')
        order by
          case status when 'dead_letter' then 0 when 'leased' then 1 else 2 end,
          created_at asc
        limit 1
      ), 'null'::jsonb)
    ),
    'rate_limit', workspace_rate_limit_status(p_agent_key, 'notion-workspace', null),
    'per_agent_write_counts', coalesce((
      select jsonb_agg(jsonb_build_object(
        'agent', actor,
        'enqueued_7d', enqueued,
        'leased_7d', leased,
        'acked_7d', acked,
        'retry_scheduled_7d', retry_scheduled,
        'dead_lettered_7d', dead_lettered,
        'total_write_events_7d', total
      ) order by total desc, actor)
      from (
        select
          actor,
          count(*) filter (where verb = 'write_queue.enqueued')::int as enqueued,
          count(*) filter (where verb = 'write_queue.leased')::int as leased,
          count(*) filter (where verb = 'write_queue.acked')::int as acked,
          count(*) filter (where verb = 'write_queue.retry_scheduled')::int as retry_scheduled,
          count(*) filter (where verb = 'write_queue.dead_lettered')::int as dead_lettered,
          count(*)::int as total
        from events
        where object_type = 'write_queue'
          and ts >= now() - interval '7 days'
        group by actor
      ) s
    ), '[]'::jsonb),
    'mcp_connections', coalesce((
      select jsonb_agg(jsonb_build_object(
        'config_key', key,
        'agent', value::jsonb ->> 'agent',
        'revoked', coalesce((value::jsonb ->> 'revoked')::boolean, false),
        'token_hash_prefix', left(value::jsonb ->> 'token_sha256', 12),
        'token_age_days', round(extract(epoch from now() - created_at) / 86400.0, 2),
        'expires_at', value::jsonb ->> 'expires_at',
        'days_until_expiry', round(extract(epoch from ((value::jsonb ->> 'expires_at')::timestamptz - now())) / 86400.0, 2),
        'rate_limit_per_minute', (value::jsonb ->> 'rate_limit_per_minute')::int
      ) order by key)
      from app_config
      where key like 'mcp_proxy_token_%'
    ), '[]'::jsonb),
    'weekly_credit_burn', jsonb_build_object(
      'source', 'events.mcp_proxy.call last 7 days',
      'mcp_proxy_calls_7d', coalesce((
        select count(*)::int
        from events
        where verb = 'mcp_proxy.call'
          and ts >= now() - interval '7 days'
      ), 0),
      'by_agent', coalesce((
        select jsonb_agg(jsonb_build_object(
          'agent', agent,
          'calls_7d', calls,
          'ok_7d', ok,
          'denied_7d', denied
        ) order by calls desc, agent)
        from (
          select
            coalesce(payload ->> 'agent', actor) as agent,
            count(*)::int as calls,
            count(*) filter (where payload ->> 'result' = 'ok')::int as ok,
            count(*) filter (where payload ->> 'result' <> 'ok')::int as denied
          from events
          where verb = 'mcp_proxy.call'
            and ts >= now() - interval '7 days'
          group by coalesce(payload ->> 'agent', actor)
        ) s
      ), '[]'::jsonb),
      'configured_weekly_budget', coalesce((
        select value::jsonb
        from app_config
        where key = 'weekly_credit_budget'
        limit 1
      ), 'null'::jsonb)
    )
  );
end $$;

create or replace function board_query(p_agent_key text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_agent text;
begin
  v_agent := _auth_agent(p_agent_key);
  perform expire_leases();
  return jsonb_build_object(
    'generated_at', now(),
    'tasks_by_state', coalesce((
      select jsonb_object_agg(state, items) from (
        select t.state, jsonb_agg(_task_summary(t) order by
                 case t.priority when 'urgent' then 0 when 'high' then 1 when 'medium' then 2 else 3 end,
                 t.created_at) as items
        from tasks t
        where t.superseded_by is null
          and (t.state not in ('done','cancelled') or t.created_at > now() - interval '7 days')
        group by t.state) s), '{}'),
    'unclaimed_queue', coalesce((
      select jsonb_agg(_task_summary(t) order by
               case t.priority when 'urgent' then 0 when 'high' then 1 when 'medium' then 2 else 3 end,
               t.created_at)
      from tasks t
      where t.state = 'ready' and t.claimed_by is null and t.superseded_by is null), '[]'),
    'decisions_by_approver', coalesce((
      select jsonb_object_agg(approver, items) from (
        select d.approver, jsonb_agg(jsonb_build_object(
            'id', d.id, 'question', d.question, 'options', d.options,
            'default_action', d.default_action, 'artifact_url', d.artifact_url,
            'blocking_task_id', d.blocking_task_id, 'opened_by', d.opened_by,
            'age_hours', round(extract(epoch from now() - d.opened_at) / 3600, 1),
            'sla_remaining_hours', round(extract(epoch from d.opened_at + make_interval(hours => d.sla_hours) - now()) / 3600, 1),
            'escalated', d.escalated_at is not null
          ) order by d.opened_at) as items
        from decisions d where d.resolved_at is null
        group by d.approver) s), '{}'),
    'open_requests', coalesce((
      select jsonb_agg(jsonb_build_object('id', r.id, 'type', r.type,
          'request', left(r.request, 200), 'requester', r.requester, 'fulfiller', r.fulfiller,
          'requires_approval', r.requires_approval,
          'age_hours', round(extract(epoch from now() - r.created_at) / 3600, 1)) order by r.created_at)
      from data_requests r where r.status = 'open'), '[]'),
    'cron_health', coalesce((
      select jsonb_agg(jsonb_build_object(
          'id', c.id, 'owner', c.owner_agent, 'schedule', c.schedule,
          'expected_interval_minutes', c.expected_interval_minutes,
          'last_run_at', lr.ran_at, 'last_status', lr.status,
          'runs_24h', coalesce(r24.n, 0),
          'health', case
            when c.status <> 'active' then c.status
            when lr.ran_at is null then 'never_ran'
            when lr.status = 'failed' then 'failed'
            when now() - lr.ran_at > 2 * make_interval(mins => c.expected_interval_minutes) then 'late'
            else 'ok' end
        ) order by c.id)
      from crons c
      left join lateral (select ran_at, status from cron_runs where cron_id = c.id
                         order by ran_at desc limit 1) lr on true
      left join lateral (select count(*) n from cron_runs where cron_id = c.id
                         and ran_at > now() - interval '24 hours') r24 on true), '[]'),
    'programs', coalesce((
      select jsonb_agg(jsonb_build_object('id', p.id, 'type', p.type, 'name', p.name,
          'status', p.status, 'open_tasks', (select count(*) from tasks t
            where t.program_id = p.id and t.superseded_by is null
              and t.state not in ('done','cancelled'))) order by p.created_at)
      from programs p where p.status = 'active'), '[]'),
    'ops_panel', jsonb_build_object(
      'rate_limit', workspace_rate_limit_status(p_agent_key, 'notion-workspace', null),
      'ops_health', _ops_health_panel(p_agent_key)
    )
  );
end $$;

revoke execute on function _ops_health_panel(text) from public, anon, authenticated;
grant execute on function board_query(text) to anon, authenticated;
