-- Backbone BLD-202 — workspace token bucket limiter for downstream writers.
-- Writers are serialized before lease, so over-budget bursts wait instead of
-- creating downstream 429s.

create table if not exists workspace_rate_limit_buckets (
  scope              text not null check (scope in ('workspace', 'integration')),
  workspace_key      text not null,
  integration_key    text not null default '*',
  capacity           numeric not null check (capacity > 0),
  reserve_ratio      numeric not null default 0 check (reserve_ratio >= 0 and reserve_ratio < 1),
  refill_per_second  numeric not null check (refill_per_second > 0),
  tokens             numeric not null check (tokens >= 0),
  last_refill_at     timestamptz not null default now(),
  slo                jsonb not null default '{}',
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  primary key (scope, workspace_key, integration_key)
);

alter table workspace_rate_limit_buckets enable row level security;
revoke all on workspace_rate_limit_buckets from anon, authenticated;

create or replace function _workspace_rate_limit_default_slo()
returns jsonb
language sql immutable as $$
  select jsonb_build_object(
    'workspace_window_seconds', 300,
    'workspace_contract_budget_requests', 1000,
    'workspace_reserve_ratio', 0.20,
    'workspace_usable_budget_requests', 800,
    'integration_avg_rps', 3,
    'behavior', 'serialize over-budget writer leases; do not throw downstream 429s'
  )
$$;

create or replace function _workspace_rate_limit_ensure(
  p_workspace_key text,
  p_integration_key text
) returns void
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(p_workspace_key, '') = '' then
    raise exception 'workspace_key cannot be blank.';
  end if;
  if coalesce(p_integration_key, '') = '' then
    raise exception 'integration_key cannot be blank.';
  end if;

  insert into workspace_rate_limit_buckets (
    scope, workspace_key, integration_key, capacity, reserve_ratio,
    refill_per_second, tokens, slo
  ) values (
    'workspace', p_workspace_key, '*', 800, 0.20,
    800.0 / 300.0, 800, _workspace_rate_limit_default_slo()
  )
  on conflict (scope, workspace_key, integration_key) do nothing;

  insert into workspace_rate_limit_buckets (
    scope, workspace_key, integration_key, capacity, reserve_ratio,
    refill_per_second, tokens, slo
  ) values (
    'integration', p_workspace_key, p_integration_key, 900, 0,
    3.0, 900, _workspace_rate_limit_default_slo()
  )
  on conflict (scope, workspace_key, integration_key) do nothing;
end $$;

create or replace function workspace_rate_limit_acquire(
  p_agent_key text,
  p_workspace_key text default 'notion-workspace',
  p_integration_key text default 'default',
  p_request_count int default 1,
  p_now timestamptz default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_now timestamptz := coalesce(p_now, now());
  v_ws workspace_rate_limit_buckets;
  v_int workspace_rate_limit_buckets;
  v_ws_tokens numeric;
  v_int_tokens numeric;
  v_ws_deficit numeric;
  v_int_deficit numeric;
  v_retry_seconds int;
begin
  perform _auth_agent(p_agent_key);
  if coalesce(p_workspace_key, '') = '' then
    raise exception 'workspace_key cannot be blank.';
  end if;
  if coalesce(p_integration_key, '') = '' then
    raise exception 'integration_key cannot be blank.';
  end if;
  if p_request_count is null or p_request_count < 1 or p_request_count > 10000 then
    raise exception 'request_count must be between 1 and 10000.';
  end if;

  perform _workspace_rate_limit_ensure(p_workspace_key, p_integration_key);

  select * into v_ws
  from workspace_rate_limit_buckets
  where scope = 'workspace'
    and workspace_key = p_workspace_key
    and integration_key = '*'
  for update;

  select * into v_int
  from workspace_rate_limit_buckets
  where scope = 'integration'
    and workspace_key = p_workspace_key
    and integration_key = p_integration_key
  for update;

  v_ws_tokens := least(
    v_ws.capacity,
    v_ws.tokens + greatest(0, extract(epoch from v_now - v_ws.last_refill_at)) * v_ws.refill_per_second
  );
  v_int_tokens := least(
    v_int.capacity,
    v_int.tokens + greatest(0, extract(epoch from v_now - v_int.last_refill_at)) * v_int.refill_per_second
  );

  if v_ws_tokens >= p_request_count and v_int_tokens >= p_request_count then
    update workspace_rate_limit_buckets
    set tokens = v_ws_tokens - p_request_count,
        last_refill_at = v_now,
        updated_at = now()
    where scope = 'workspace'
      and workspace_key = p_workspace_key
      and integration_key = '*';

    update workspace_rate_limit_buckets
    set tokens = v_int_tokens - p_request_count,
        last_refill_at = v_now,
        updated_at = now()
    where scope = 'integration'
      and workspace_key = p_workspace_key
      and integration_key = p_integration_key;

    return jsonb_build_object(
      'granted', true,
      'serialized', false,
      'workspace_key', p_workspace_key,
      'integration_key', p_integration_key,
      'request_count', p_request_count,
      'tokens_remaining', jsonb_build_object(
        'workspace', round(v_ws_tokens - p_request_count, 3),
        'integration', round(v_int_tokens - p_request_count, 3)
      ),
      'service_objectives', _workspace_rate_limit_default_slo()
    );
  end if;

  v_ws_deficit := greatest(0, p_request_count - v_ws_tokens);
  v_int_deficit := greatest(0, p_request_count - v_int_tokens);
  v_retry_seconds := greatest(
    case when v_ws_deficit > 0 then ceiling(v_ws_deficit / v_ws.refill_per_second)::int else 0 end,
    case when v_int_deficit > 0 then ceiling(v_int_deficit / v_int.refill_per_second)::int else 0 end
  );

  update workspace_rate_limit_buckets
  set tokens = v_ws_tokens,
      last_refill_at = v_now,
      updated_at = now()
  where scope = 'workspace'
    and workspace_key = p_workspace_key
    and integration_key = '*';

  update workspace_rate_limit_buckets
  set tokens = v_int_tokens,
      last_refill_at = v_now,
      updated_at = now()
  where scope = 'integration'
    and workspace_key = p_workspace_key
    and integration_key = p_integration_key;

  return jsonb_build_object(
    'granted', false,
    'serialized', true,
    'workspace_key', p_workspace_key,
    'integration_key', p_integration_key,
    'request_count', p_request_count,
    'retry_after_seconds', greatest(v_retry_seconds, 1),
    'would_429_without_limiter', true,
    'tokens_available', jsonb_build_object(
      'workspace', round(v_ws_tokens, 3),
      'integration', round(v_int_tokens, 3)
    ),
    'service_objectives', _workspace_rate_limit_default_slo()
  );
end $$;

create or replace function workspace_rate_limit_status(
  p_agent_key text,
  p_workspace_key text default 'notion-workspace',
  p_integration_key text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_now timestamptz := now();
begin
  perform _auth_agent(p_agent_key);
  perform _workspace_rate_limit_ensure(p_workspace_key, coalesce(p_integration_key, 'default'));

  return jsonb_build_object(
    'service_objectives', _workspace_rate_limit_default_slo(),
    'workspace_key', p_workspace_key,
    'workspace', (
      select jsonb_build_object(
        'capacity', capacity,
        'tokens_available', round(least(capacity, tokens + greatest(0, extract(epoch from v_now - last_refill_at)) * refill_per_second), 3),
        'headroom_percent', round(
          100 * least(capacity, tokens + greatest(0, extract(epoch from v_now - last_refill_at)) * refill_per_second) / capacity,
          1
        ),
        'reserve_ratio', reserve_ratio,
        'refill_per_second', round(refill_per_second, 3),
        'last_refill_at', last_refill_at
      )
      from workspace_rate_limit_buckets
      where scope = 'workspace'
        and workspace_key = p_workspace_key
        and integration_key = '*'
    ),
    'integrations', coalesce((
      select jsonb_agg(jsonb_build_object(
        'integration_key', integration_key,
        'capacity', capacity,
        'tokens_available', round(least(capacity, tokens + greatest(0, extract(epoch from v_now - last_refill_at)) * refill_per_second), 3),
        'headroom_percent', round(
          100 * least(capacity, tokens + greatest(0, extract(epoch from v_now - last_refill_at)) * refill_per_second) / capacity,
          1
        ),
        'refill_per_second', round(refill_per_second, 3),
        'last_refill_at', last_refill_at
      ) order by integration_key)
      from workspace_rate_limit_buckets
      where scope = 'integration'
        and workspace_key = p_workspace_key
        and (p_integration_key is null or integration_key = p_integration_key)
    ), '[]')
  );
end $$;

create or replace function write_queue_lease(
  p_agent_key text,
  p_queue_name text default 'default',
  p_lease_seconds int default 300
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_agent text;
  v_row write_queue_items;
  v_next_id uuid;
  v_expired int;
  v_rate jsonb;
begin
  v_agent := _auth_agent(p_agent_key);
  if coalesce(p_queue_name, '') = '' then
    raise exception 'queue_name cannot be blank.';
  end if;
  if p_lease_seconds < 0 then
    raise exception 'lease_seconds must be zero or greater.';
  end if;

  v_expired := _write_queue_expire_leases();

  select id into v_next_id
  from write_queue_items
  where queue_name = p_queue_name
    and status = 'queued'
    and available_at <= now()
  order by available_at, created_at
  for update skip locked
  limit 1;

  if v_next_id is null then
    return jsonb_build_object('leased', false, 'queue_name', p_queue_name, 'expired_leases', v_expired);
  end if;

  v_rate := workspace_rate_limit_acquire(p_agent_key, 'notion-workspace', p_queue_name, 1, null);
  if coalesce((v_rate->>'granted')::boolean, false) is not true then
    return jsonb_build_object(
      'leased', false,
      'queue_name', p_queue_name,
      'expired_leases', v_expired,
      'rate_limited', true,
      'rate_limit', v_rate
    );
  end if;

  update write_queue_items q
  set status = 'leased',
      leased_by = v_agent,
      lease_expires_at = now() + make_interval(secs => greatest(p_lease_seconds, 0)),
      updated_at = now()
  where q.id = v_next_id
  returning q.* into v_row;

  perform _emit(v_agent, 'write_queue.leased', 'write_queue', v_row.id::text,
    jsonb_build_object('queue_name', v_row.queue_name, 'lease_expires_at', v_row.lease_expires_at,
      'retry_count', v_row.retry_count, 'expired_leases', v_expired, 'rate_limit', v_rate),
    'standard');

  return jsonb_build_object(
    'leased', true,
    'expired_leases', v_expired,
    'rate_limit', v_rate,
    'item', _write_queue_summary(v_row)
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
      'rate_limit', workspace_rate_limit_status(p_agent_key, 'notion-workspace', null)
    )
  );
end $$;

revoke execute on function
  _workspace_rate_limit_default_slo(),
  _workspace_rate_limit_ensure(text, text)
from public, anon, authenticated;

grant execute on function
  workspace_rate_limit_acquire(text, text, text, int, timestamptz),
  workspace_rate_limit_status(text, text, text),
  write_queue_lease(text, text, int),
  board_query(text)
to anon, authenticated;
