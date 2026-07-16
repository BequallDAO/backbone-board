-- P0: compact routing reads and namespace isolation.
--
-- This migration is additive at the RPC boundary: board_query(text) remains
-- unchanged while agent_inbox and board_summary provide bounded alternatives.

alter table tasks
  add column if not exists title text,
  add column if not exists environment text not null default 'live',
  add column if not exists queue_namespace text not null default 'general',
  add column if not exists suggested_capabilities text[] not null default '{}',
  add column if not exists suggested_resources text[] not null default '{}',
  add column if not exists expires_at timestamptz;

-- Capabilities are discovery and preparation hints, never authorization gates.
-- Preserve old dispatch data while clearing the legacy hard-gate field so old
-- readers remain compatible and new claim logic cannot strand work.
update tasks
set suggested_capabilities = required_capabilities
where cardinality(suggested_capabilities) = 0
  and cardinality(required_capabilities) > 0;

update tasks
set required_capabilities = '{}'
where cardinality(required_capabilities) > 0;

-- Isolate the historical harness/schema-probe rows that predate environment.
update tasks
set environment = 'test',
    queue_namespace = 'sandbox',
    expires_at = coalesce(expires_at, created_at + interval '7 days')
where environment = 'live'
  and (
    external_id like 'test-%'
    or external_id = 'test-schema-probe'
    or deliverable_spec ilike 'TEST %'
  );

-- Program backlogs are queried through program_query unless a compact inbox
-- explicitly includes an urgent item ranked as useful for the caller.
update tasks
set queue_namespace = 'program:' || program_id::text
where environment = 'live'
  and program_id is not null
  and queue_namespace = 'general';

-- Give legacy live rows stable identities before enforcing the new invariant.
update tasks
set external_id = 'legacy:' || id::text
where environment = 'live' and external_id is null;

update tasks
set title = left(
  regexp_replace(trim(coalesce(nullif(deliverable_spec, ''), external_id, id::text)), '\s+', ' ', 'g'),
  160
)
where title is null or trim(title) = '';

alter table tasks alter column title set not null;

alter table tasks drop constraint if exists tasks_environment_check;
alter table tasks add constraint tasks_environment_check
  check (environment in ('live', 'test'));

alter table tasks drop constraint if exists tasks_queue_namespace_check;
alter table tasks add constraint tasks_queue_namespace_check check (
  queue_namespace in ('general', 'ops', 'sandbox')
  or queue_namespace ~ '^program:[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
);

alter table tasks drop constraint if exists tasks_title_check;
alter table tasks add constraint tasks_title_check
  check (char_length(trim(title)) between 1 and 160);

alter table tasks drop constraint if exists tasks_live_external_id_check;
alter table tasks add constraint tasks_live_external_id_check
  check (environment <> 'live' or nullif(trim(external_id), '') is not null);

alter table tasks drop constraint if exists tasks_test_expiry_check;
alter table tasks add constraint tasks_test_expiry_check
  check (environment <> 'test' or expires_at is not null);

create index if not exists tasks_live_inbox_idx
  on tasks (queue_namespace, state, priority, deadline, created_at)
  where environment = 'live' and superseded_by is null;

create index if not exists tasks_test_expiry_idx
  on tasks (expires_at)
  where environment = 'test';

-------------------------------------------------------------------------------
-- Compact representations
-------------------------------------------------------------------------------

create or replace function _task_summary(t tasks) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'id', t.id, 'external_id', t.external_id, 'title', t.title,
    'environment', t.environment, 'queue_namespace', t.queue_namespace,
    'program_id', t.program_id,
    'workflow', t.workflow_id || ' v' || t.workflow_version, 'state', t.state,
    'type', t.type, 'priority', t.priority, 'deadline', t.deadline,
    'deliverable_spec', left(t.deliverable_spec, 300),
    'output_location', t.output_location, 'drive_folder', t.drive_folder,
    'suggested_capabilities', t.suggested_capabilities,
    'suggested_resources', t.suggested_resources,
    'claimed_by', t.claimed_by, 'lease_expires_at', t.lease_expires_at,
    'supersedes_id', t.supersedes_id, 'created_by', t.created_by,
    'created_at', t.created_at, 'expires_at', t.expires_at
  )
$$;

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

-------------------------------------------------------------------------------
-- task_create routing invariants
-------------------------------------------------------------------------------

create or replace function task_create(p_agent_key text, p_task jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_agent text; v_row tasks; v_existing tasks; v_wf workflows;
  v_wf_id text; v_wf_version int; v_type text; v_priority text; v_output text;
  v_environment text; v_namespace text; v_title text; v_expires_at timestamptz;
  v_program_id uuid; v_suggested_capabilities text[]; v_suggested_resources text[];
begin
  v_agent := _auth_agent(p_agent_key);

  v_environment := coalesce(nullif(p_task->>'environment', ''), 'live');
  if v_environment not in ('live', 'test') then
    raise exception 'Unknown environment "%". Use live or test.', v_environment;
  end if;
  if v_environment = 'live' and nullif(trim(p_task->>'external_id'), '') is null then
    raise exception 'external_id is required for live tasks. Supply a stable idempotency key, or use environment=test for harness work.';
  end if;

  -- Idempotent dispatch: same external_id returns the existing row, never an error.
  if nullif(trim(p_task->>'external_id'), '') is not null then
    select * into v_existing from tasks where external_id = p_task->>'external_id';
    if found then
      return jsonb_build_object('task', _task_full(v_existing), 'existing', true,
        'notice', 'A task with this external_id already exists; returning it. No duplicate was created.');
    end if;
  end if;

  v_type := coalesce(p_task->>'type', 'other');
  if v_type not in ('document','email','analysis','research','sequence','proposal','other') then
    raise exception 'Unknown task type "%". Use one of: document, email, analysis, research, sequence, proposal, other.', v_type;
  end if;
  v_priority := coalesce(p_task->>'priority', 'medium');
  if v_priority not in ('urgent','high','medium','low') then
    raise exception 'Unknown priority "%". Use one of: urgent, high, medium, low.', v_priority;
  end if;
  v_output := coalesce(p_task->>'output_location', 'drive');
  if v_output not in ('drive','workspace','thread') then
    raise exception 'Unknown output_location "%". Use one of: drive, workspace, thread.', v_output;
  end if;
  if coalesce(p_task->>'deliverable_spec', '') = '' then
    raise exception 'deliverable_spec is required: describe exactly what the finished deliverable must contain.';
  end if;

  v_wf_id := coalesce(p_task->>'workflow_id', 'default');
  v_wf_version := coalesce((p_task->>'workflow_version')::int,
                           (select max(version) from workflows where id = v_wf_id));
  select * into v_wf from workflows where id = v_wf_id and version = v_wf_version;
  if not found then
    raise exception 'Unknown workflow "%" v%. Define it with workflow_define or omit workflow_id to use "default".', v_wf_id, v_wf_version;
  end if;

  v_program_id := nullif(p_task->>'program_id', '')::uuid;
  if v_program_id is not null
     and not exists (select 1 from programs where id = v_program_id) then
    raise exception 'Unknown program_id %. Create the program first with program_create, or omit program_id for an ad-hoc task.', v_program_id;
  end if;

  v_namespace := nullif(p_task->>'queue_namespace', '');
  if v_namespace is null then
    v_namespace := case
      when v_environment = 'test' then 'sandbox'
      when v_program_id is not null then 'program:' || v_program_id::text
      else 'general'
    end;
  end if;
  if v_namespace not in ('general', 'ops', 'sandbox')
     and v_namespace !~ '^program:[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' then
    raise exception 'Invalid queue_namespace "%". Use general, ops, sandbox, or program:<uuid>.', v_namespace;
  end if;
  if v_environment = 'test' and v_namespace <> 'sandbox' then
    raise exception 'Test tasks must use queue_namespace=sandbox.';
  end if;
  if v_environment = 'live' and v_namespace = 'sandbox' then
    raise exception 'Live tasks cannot use queue_namespace=sandbox. Use environment=test or a live namespace.';
  end if;
  if v_program_id is not null and v_environment = 'live'
     and v_namespace <> ('program:' || v_program_id::text) then
    raise exception 'Program tasks must use queue_namespace=program:% unless environment=test.', v_program_id;
  end if;

  v_title := left(regexp_replace(trim(coalesce(nullif(p_task->>'title', ''),
    p_task->>'deliverable_spec')), '\s+', ' ', 'g'), 160);
  v_expires_at := nullif(p_task->>'expires_at', '')::timestamptz;
  if v_environment = 'test' then
    v_expires_at := coalesce(v_expires_at, now() + interval '7 days');
  end if;
  v_suggested_capabilities := coalesce(
    _jsonb_text_array(p_task->'suggested_capabilities'),
    _jsonb_text_array(p_task->'required_capabilities'),
    '{}'
  );
  v_suggested_resources := coalesce(
    _jsonb_text_array(p_task->'suggested_resources'),
    '{}'
  );

  insert into tasks (external_id, title, environment, queue_namespace, expires_at,
    program_id, workflow_id, workflow_version, state,
    type, priority, deadline, context, data_intel, wiki_page, reference_docs,
    deliverable_spec, output_location, drive_folder, skill_route, voice_rules,
    required_capabilities, suggested_capabilities, suggested_resources, created_by)
  values (
    nullif(trim(p_task->>'external_id'), ''), v_title, v_environment, v_namespace, v_expires_at,
    v_program_id, v_wf_id, v_wf_version, v_wf.states[1],
    v_type, v_priority, (p_task->>'deadline')::timestamptz,
    p_task->>'context', p_task->>'data_intel', p_task->>'wiki_page',
    _jsonb_text_array(p_task->'reference_docs'),
    p_task->>'deliverable_spec', v_output, p_task->>'drive_folder',
    p_task->>'skill_route', p_task->>'voice_rules',
    '{}', v_suggested_capabilities, v_suggested_resources,
    v_agent)
  returning * into v_row;

  perform _emit(v_agent, 'task.created', 'task', v_row.id::text,
    jsonb_build_object('title', v_row.title, 'type', v_row.type,
      'priority', v_row.priority, 'external_id', v_row.external_id,
      'environment', v_row.environment, 'queue_namespace', v_row.queue_namespace,
      'suggested_capabilities', v_row.suggested_capabilities,
      'suggested_resources', v_row.suggested_resources, 'deadline', v_row.deadline),
    case when v_row.priority in ('urgent','high') then 'major' else 'standard' end);

  return jsonb_build_object('task', _task_full(v_row), 'existing', false);
end $$;

-- Capability and resource metadata is advisory. The claim response surfaces
-- gaps so the agent can prepare, ask for help, or proceed with an alternative;
-- it never rejects otherwise valid work for a self-declared capability gap.
create or replace function task_claim(
  p_agent_key text, p_task_id uuid, p_ttl_minutes int default 240
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_agent text; v_task tasks; v_caps text[]; v_gaps text[];
  v_prev_owner text; v_prev_lease timestamptz; v_row tasks; v_renewal boolean;
begin
  v_agent := _auth_agent(p_agent_key);
  select * into v_task from tasks where id = p_task_id;
  if not found then
    raise exception 'No task with id %. Use agent_inbox or board_summary to find the task you mean.', p_task_id;
  end if;

  if v_task.superseded_by is not null then
    return jsonb_build_object('claimed', false, 'reason', 'superseded',
      'superseded_by', v_task.superseded_by,
      'message', 'This task was superseded. Do not build it. Claim the replacement task ' || v_task.superseded_by || ' instead.');
  end if;
  if v_task.state in ('done','cancelled') then
    return jsonb_build_object('claimed', false, 'reason', 'closed', 'state', v_task.state,
      'message', 'This task is already ' || v_task.state || '. Nothing to build.');
  end if;

  select capabilities into v_caps from agents where id = v_agent;
  select array(
    select unnest(v_task.suggested_capabilities)
    except
    select unnest(v_caps)
  ) into v_gaps;

  v_prev_owner := v_task.claimed_by;
  v_prev_lease := v_task.lease_expires_at;
  v_renewal := coalesce(v_prev_owner = v_agent, false);

  update tasks
  set claimed_by = v_agent,
      lease_expires_at = now() + make_interval(mins => greatest(p_ttl_minutes, 0))
  where id = p_task_id
    and superseded_by is null
    and state not in ('done','cancelled')
    and (claimed_by is null or claimed_by = v_agent or lease_expires_at < now())
  returning * into v_row;

  if v_row.id is null then
    select claimed_by, lease_expires_at into v_prev_owner, v_prev_lease from tasks where id = p_task_id;
    return jsonb_build_object('claimed', false, 'reason', 'already_claimed',
      'owner', v_prev_owner, 'lease_expires_at', v_prev_lease,
      'message', 'Task is claimed by ' || v_prev_owner || ' (lease until ' || v_prev_lease || '). Do not build; coordinate with the owner or wait for the lease to expire.');
  end if;

  if v_prev_owner is not null and not v_renewal then
    perform _emit('system', 'task.lease_expired', 'task', p_task_id::text,
                  jsonb_build_object('previous_owner', v_prev_owner), 'standard');
  end if;
  perform _emit(v_agent, case when v_renewal then 'task.lease_renewed' else 'task.claimed' end,
                'task', p_task_id::text,
                jsonb_build_object('lease_expires_at', v_row.lease_expires_at,
                  'suggested_capability_gaps', v_gaps,
                  'suggested_resources', v_row.suggested_resources),
                case when v_renewal then 'routine' else 'standard' end);

  return jsonb_build_object(
    'claimed', true,
    'renewal', v_renewal,
    'task', _task_full(v_row),
    'advisory', jsonb_build_object(
      'capability_gaps', coalesce(to_jsonb(v_gaps), '[]'::jsonb),
      'suggested_resources', to_jsonb(v_row.suggested_resources),
      'message', case
        when cardinality(v_gaps) = 0 and cardinality(v_row.suggested_resources) = 0
          then 'No preparation suggestions are recorded.'
        else 'These are preparation suggestions, not claim requirements. Proceed, adapt, or request support as needed.'
      end
    )
  );
end $$;

-- Supersession creates a new live task, so it must mint a stable replacement
-- external_id when the caller does not supply one.
create or replace function task_supersede(
  p_agent_key text, p_old_task_id uuid, p_overrides jsonb default '{}'
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_agent text; v_old tasks; v_new tasks; v_prior_claimant text; v_spec jsonb;
begin
  v_agent := _auth_agent(p_agent_key);
  select * into v_old from tasks where id = p_old_task_id;
  if not found then
    raise exception 'No task with id %.', p_old_task_id;
  end if;
  if v_old.superseded_by is not null then
    raise exception 'Task % was already superseded by %. Supersede the chain head, not an old link.', p_old_task_id, v_old.superseded_by;
  end if;

  v_prior_claimant := v_old.claimed_by;
  v_spec := (_task_full(v_old)
              - 'id' - 'external_id' - 'state' - 'claimed_by' - 'lease_expires_at'
              - 'supersedes_id' - 'superseded_by' - 'created_by' - 'created_at' - 'workflow')
            || jsonb_build_object(
              'external_id', v_old.external_id || ':supersedes:' || v_old.id::text,
              'workflow_id', v_old.workflow_id,
              'workflow_version', v_old.workflow_version
            )
            || coalesce(p_overrides, '{}');

  v_new := null;
  select * into v_new from jsonb_populate_record(null::tasks,
            (select (task_create(p_agent_key, v_spec))->'task'));
  update tasks set supersedes_id = p_old_task_id where id = v_new.id;
  update tasks
  set superseded_by = v_new.id, claimed_by = null, lease_expires_at = null
  where id = p_old_task_id;

  perform _emit(v_agent, 'task.superseded', 'task', p_old_task_id::text,
    jsonb_build_object('superseded_by', v_new.id, 'prior_claimant', v_prior_claimant), 'major');

  return jsonb_build_object('old_task_id', p_old_task_id, 'new_task_id', v_new.id,
    'prior_claimant', v_prior_claimant,
    'notice', case when v_prior_claimant is not null
      then 'Prior claimant ' || v_prior_claimant || ' was released and will be notified. New work claims the new task.'
      else 'No prior claimant. New work claims the new task.' end);
end $$;

-------------------------------------------------------------------------------
-- Bounded routine reads
-------------------------------------------------------------------------------

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
          case when t.claimed_by = v_agent then 0 else 1 end as route_rank,
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
              and (t.queue_namespace = 'general'
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
        and (t.queue_namespace = 'general'
             or (t.queue_namespace like 'program:%' and t.priority = 'urgent'))),
      'suggestion_matches', (select count(*) from tasks t where t.environment = 'live'
        and t.superseded_by is null and t.state = 'ready' and t.claimed_by is null
        and t.suggested_capabilities <@ v_capabilities
        and (t.queue_namespace = 'general'
             or (t.queue_namespace like 'program:%' and t.priority = 'urgent'))),
      'suggestion_gaps', (select count(*) from tasks t where t.environment = 'live'
        and t.superseded_by is null and t.state = 'ready' and t.claimed_by is null
        and not (t.suggested_capabilities <@ v_capabilities)
        and (t.queue_namespace = 'general'
             or (t.queue_namespace like 'program:%' and t.priority = 'urgent'))),
      'requests', (select count(*) from data_requests r where r.status = 'open'
        and r.requester <> v_agent and (r.fulfiller = v_agent or r.fulfiller is null))
    )
  );
end $$;

-- Registration remains a heartbeat, but its startup payload now uses the same
-- live routing filters as agent_inbox instead of counting sandbox/program noise.
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
                                 and (t.queue_namespace = 'general'
                                   or (t.queue_namespace like 'program:%' and t.priority = 'urgent'))),
    'routing_model', 'Capabilities and resources are advisory suggestions; priority and ownership govern progress.',
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
        select coalesce(claimed_by, 'unclaimed') agent_key, count(*) n
        from tasks where environment = 'live' and superseded_by is null
          and state not in ('done','cancelled') group by claimed_by
      ) s), '{}'::jsonb),
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

-- New functions default to PUBLIC execute. Keep the agent-key boundary explicit.
revoke execute on function _task_compact(tasks) from public, anon, authenticated;
revoke execute on function agent_inbox(text, int, timestamptz, boolean) from public;
revoke execute on function board_summary(text) from public;
grant execute on function agent_inbox(text, int, timestamptz, boolean), board_summary(text)
  to anon, authenticated;
