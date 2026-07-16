-- Backbone routing repair: make agent_inbox honor skill_route when present.
-- P0 introduced skill_route as the only live routing field before durable
-- assigned_to exists. Without this filter, compact inboxes still show work
-- intended for other agents when capability gaps are advisory.

create or replace function _task_compact(t tasks) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'id', t.id,
    'external_id', t.external_id,
    'title', t.title,
    'state', t.state,
    'priority', t.priority,
    'deadline', t.deadline,
    'program_id', t.program_id,
    'queue_namespace', t.queue_namespace,
    'skill_route', t.skill_route,
    'suggested_capabilities', t.suggested_capabilities,
    'suggested_resources', t.suggested_resources,
    'claimed_by', t.claimed_by,
    'lease_expires_at', t.lease_expires_at,
    'readiness', case
      when t.state = 'blocked' then 'Blocked; use task_get for the blocking decision or data dependency.'
      when t.claimed_by is not null then 'Claimed and executable by ' || t.claimed_by || '.'
      when t.deadline is not null and t.deadline < now() then 'Executable and overdue.'
      else 'Executable now.'
    end
  )
$$;

create or replace function agent_inbox(
  p_agent_key text,
  p_limit int default 10,
  p_cursor timestamptz default null,
  p_include_open_pool boolean default true
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_agent text; v_capabilities text[]; v_limit int; v_now timestamptz := now();
begin
  v_agent := _auth_agent(p_agent_key);
  select capabilities into v_capabilities from agents where id = v_agent;
  v_limit := greatest(1, least(coalesce(p_limit, 10), 10));
  perform expire_leases();

  return jsonb_build_object(
    'generated_at', v_now,
    'agent_id', v_agent,
    'cursor', v_now,
    'tasks', coalesce((
      select jsonb_agg(
        _task_compact(q.task_row) || jsonb_build_object(
          'suggestion_match', q.capability_gap_count = 0,
          'capability_gaps', q.capability_gaps
        )
        order by q.route_rank, q.priority_rank, q.capability_gap_count,
                 q.deadline nulls last, q.created_at
      )
      from (
        select t as task_row, t.deadline, t.created_at,
          case when t.claimed_by = v_agent then 0
               when t.skill_route = v_agent then 1
               else 2 end as route_rank,
          case t.priority when 'urgent' then 0 when 'high' then 1
                          when 'medium' then 2 else 3 end as priority_rank,
          fit.capability_gaps,
          cardinality(fit.capability_gaps) as capability_gap_count
        from tasks t
        cross join lateral (
          select array(
            select unnest(t.suggested_capabilities)
            except
            select unnest(v_capabilities)
          ) as capability_gaps
        ) fit
        where t.environment = 'live'
          and t.superseded_by is null
          and t.state not in ('done', 'cancelled')
          and (t.expires_at is null or t.expires_at > v_now)
          and (
            t.claimed_by = v_agent
            or (
              coalesce(p_include_open_pool, true)
              and t.claimed_by is null
              and t.state = 'ready'
              and (t.skill_route is null or t.skill_route = v_agent)
              and (t.queue_namespace = 'general'
                   or t.skill_route = v_agent
                   or (t.queue_namespace like 'program:%' and t.priority = 'urgent'))
              and (p_cursor is null or t.created_at > p_cursor)
            )
          )
        order by route_rank, priority_rank, capability_gap_count,
                 t.deadline nulls last, t.created_at
        limit v_limit
      ) q
    ), '[]'::jsonb),
    'requests', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', r.id, 'type', r.type, 'request', left(r.request, 160),
        'requester', r.requester, 'requires_approval', r.requires_approval,
        'created_at', r.created_at
      ) order by r.created_at)
      from (
        select * from data_requests
        where status = 'open'
          and requester <> v_agent
          and (fulfiller = v_agent or fulfiller is null)
          and (p_cursor is null or created_at > p_cursor)
        order by created_at
        limit v_limit
      ) r
    ), '[]'::jsonb),
    'counts', jsonb_build_object(
      'claimed', (select count(*) from tasks t where t.environment = 'live'
        and t.superseded_by is null and t.state not in ('done','cancelled')
        and t.claimed_by = v_agent),
      'open_pool_visible', (select count(*) from tasks t where t.environment = 'live'
        and t.superseded_by is null and t.state = 'ready' and t.claimed_by is null
        and (t.skill_route is null or t.skill_route = v_agent)
        and (t.queue_namespace = 'general'
             or t.skill_route = v_agent
             or (t.queue_namespace like 'program:%' and t.priority = 'urgent'))),
      'suggestion_matches', (select count(*) from tasks t where t.environment = 'live'
        and t.superseded_by is null and t.state = 'ready' and t.claimed_by is null
        and (t.skill_route is null or t.skill_route = v_agent)
        and t.suggested_capabilities <@ v_capabilities
        and (t.queue_namespace = 'general'
             or t.skill_route = v_agent
             or (t.queue_namespace like 'program:%' and t.priority = 'urgent'))),
      'suggestion_gaps', (select count(*) from tasks t where t.environment = 'live'
        and t.superseded_by is null and t.state = 'ready' and t.claimed_by is null
        and (t.skill_route is null or t.skill_route = v_agent)
        and not (t.suggested_capabilities <@ v_capabilities)
        and (t.queue_namespace = 'general'
             or t.skill_route = v_agent
             or (t.queue_namespace like 'program:%' and t.priority = 'urgent'))),
      'requests', (select count(*) from data_requests r where r.status = 'open'
        and r.requester <> v_agent and (r.fulfiller = v_agent or r.fulfiller is null))
    )
  );
end $$;

create or replace function register_agent(
  p_agent_key text, p_capabilities text[] default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_agent text; v_first boolean; v_row agents;
begin
  v_agent := _auth_agent(p_agent_key);
  select last_heartbeat is null into v_first from agents where id = v_agent;
  update agents
  set last_heartbeat = now(),
      capabilities = coalesce(p_capabilities, capabilities)
  where id = v_agent
  returning * into v_row;
  if v_first then
    perform _emit(v_agent, 'agent.registered', 'agent', v_agent,
                  jsonb_build_object('capabilities', v_row.capabilities), 'standard');
  else
    perform _emit(v_agent, 'agent.heartbeat', 'agent', v_agent, '{}', 'routine');
  end if;
  return jsonb_build_object(
    'agent', jsonb_build_object('id', v_row.id, 'human_owner', v_row.human_owner,
                                'capabilities', v_row.capabilities, 'status', v_row.status),
    'my_claimed_tasks', (select coalesce(jsonb_agg(_task_compact(t)), '[]'::jsonb)
                         from tasks t where t.environment = 'live'
                           and t.claimed_by = v_agent and t.superseded_by is null
                           and t.state not in ('done','cancelled')),
    'unclaimed_ready_for_me', (select count(*) from tasks t
                               where t.environment = 'live' and t.state = 'ready'
                                 and t.claimed_by is null and t.superseded_by is null
                                 and (t.skill_route is null or t.skill_route = v_agent)
                                 and (t.queue_namespace = 'general'
                                   or t.skill_route = v_agent
                                   or (t.queue_namespace like 'program:%' and t.priority = 'urgent'))),
    'routing_model', 'skill_route directs compact inbox visibility; capabilities and resources remain advisory suggestions.',
    'open_requests_for_me', (select count(*) from data_requests
                             where status = 'open' and (fulfiller = v_agent or fulfiller is null)
                               and requester <> v_agent)
  );
end $$;

create or replace function board_summary(p_agent_key text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_agent text; v_now timestamptz := now(); v_stale_claims int;
begin
  v_agent := _auth_agent(p_agent_key);
  select count(*) into v_stale_claims
  from tasks where environment = 'live' and lease_expires_at < v_now;
  perform expire_leases();

  return jsonb_build_object(
    'generated_at', v_now,
    'counts', jsonb_build_object(
      'by_state', coalesce((select jsonb_object_agg(state, n) from (
        select state, count(*) n from tasks where environment = 'live'
          and superseded_by is null group by state
      ) s), '{}'::jsonb),
      'by_priority', coalesce((select jsonb_object_agg(priority, n) from (
        select priority, count(*) n from tasks where environment = 'live'
          and superseded_by is null and state not in ('done','cancelled') group by priority
      ) s), '{}'::jsonb),
      'by_program', coalesce((select jsonb_object_agg(program_key, n) from (
        select coalesce(program_id::text, 'none') program_key, count(*) n
        from tasks where environment = 'live' and superseded_by is null
          and state not in ('done','cancelled') group by program_id
      ) s), '{}'::jsonb),
      'by_agent', coalesce((select jsonb_object_agg(agent_key, n) from (
        select coalesce(claimed_by, skill_route, 'unclaimed') agent_key, count(*) n
        from tasks where environment = 'live' and superseded_by is null
          and state not in ('done','cancelled') group by coalesce(claimed_by, skill_route, 'unclaimed')
      ) s), '{}'::jsonb),
      'unclaimed_unrouted', (select count(*) from tasks where environment = 'live'
        and superseded_by is null and state not in ('done','cancelled')
        and claimed_by is null and skill_route is null),
      'unroutable', (select count(*) from tasks where environment = 'live'
        and superseded_by is null and state = 'unroutable'),
      'with_suggested_resources', (select count(*) from tasks where environment = 'live'
        and superseded_by is null and state not in ('done','cancelled')
        and cardinality(suggested_resources) > 0),
      'stale_claims_reclaimed', v_stale_claims,
      'open_decisions', (select count(*) from decisions where resolved_at is null),
      'breached_decision_slas', (select count(*) from decisions where resolved_at is null
        and opened_at + make_interval(hours => sla_hours) < v_now)
    ),
    'top_urgent', coalesce((select jsonb_agg(_task_compact(t.task_row) order by
        t.deadline nulls last, t.created_at) from (
      select q as task_row, q.deadline, q.created_at from tasks q
      where environment = 'live' and superseded_by is null
        and state not in ('done','cancelled') and priority = 'urgent'
      order by deadline nulls last, created_at limit 5
    ) t), '[]'::jsonb),
    'top_overdue', coalesce((select jsonb_agg(_task_compact(t.task_row) order by
        t.deadline, t.created_at) from (
      select q as task_row, q.deadline, q.created_at from tasks q
      where environment = 'live' and superseded_by is null
        and state not in ('done','cancelled') and deadline < v_now
      order by deadline, created_at limit 5
    ) t), '[]'::jsonb),
    'open_decisions', coalesce((select jsonb_agg(jsonb_build_object(
        'id', d.id, 'approver', d.approver, 'question', left(d.question, 120),
        'blocking_task_id', d.blocking_task_id,
        'age_hours', round(extract(epoch from v_now - d.opened_at) / 3600, 1),
        'sla_remaining_hours', round(extract(epoch from d.opened_at
          + make_interval(hours => d.sla_hours) - v_now) / 3600, 1),
        'escalated', d.escalated_at is not null
      ) order by d.opened_at) from (
        select * from decisions where resolved_at is null order by opened_at limit 10
      ) d), '[]'::jsonb)
  );
end $$;
