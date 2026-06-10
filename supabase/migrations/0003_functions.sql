-- Backbone 0003 — tool semantics as security-definer functions.
-- Every write path lives here. Each function authenticates the calling agent via its
-- key, performs its write, and appends its event(s) in the SAME transaction.
-- Error messages are read by LLM agents: always say what to do instead.

-------------------------------------------------------------------------------
-- helpers (not exposed: execute revoked from anon/authenticated at the bottom)
-------------------------------------------------------------------------------

create or replace function _auth_agent(p_agent_key text) returns text
language plpgsql stable security definer set search_path = public, extensions as $$
declare v_agent text;
begin
  if p_agent_key is null or length(p_agent_key) < 16 then
    raise exception 'Missing or malformed agent key. Set BACKBONE_AGENT_KEY to the key you were issued. If you have none, ask Jack to provision one (insert into agent_keys).';
  end if;
  select k.agent_id into v_agent
  from agent_keys k
  join agents a on a.id = k.agent_id
  where k.key_hash = encode(extensions.digest(p_agent_key, 'sha256'), 'hex')
    and k.revoked_at is null
    and a.status = 'active';
  if v_agent is null then
    raise exception 'Agent key not recognized or agent not active. Verify BACKBONE_AGENT_KEY is current; ask Jack to re-issue if it was rotated.';
  end if;
  return v_agent;
end $$;

create or replace function _emit(
  p_actor text, p_verb text, p_object_type text, p_object_id text,
  p_payload jsonb default '{}', p_significance text default 'standard',
  p_idempotency_key text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_id bigint; v_dup boolean := false;
begin
  insert into events (idempotency_key, actor, verb, object_type, object_id, payload, significance)
  values (p_idempotency_key, p_actor, p_verb, p_object_type, p_object_id, coalesce(p_payload, '{}'), p_significance)
  on conflict (idempotency_key) do nothing
  returning id into v_id;
  if v_id is null then
    v_dup := true;
    select id into v_id from events where idempotency_key = p_idempotency_key;
  end if;
  return jsonb_build_object('event_id', v_id, 'duplicate', v_dup);
end $$;

create or replace function _task_summary(t tasks) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'id', t.id, 'external_id', t.external_id, 'program_id', t.program_id,
    'workflow', t.workflow_id || ' v' || t.workflow_version, 'state', t.state,
    'type', t.type, 'priority', t.priority, 'deadline', t.deadline,
    'deliverable_spec', left(t.deliverable_spec, 300),
    'output_location', t.output_location, 'drive_folder', t.drive_folder,
    'required_capabilities', t.required_capabilities,
    'claimed_by', t.claimed_by, 'lease_expires_at', t.lease_expires_at,
    'supersedes_id', t.supersedes_id, 'created_by', t.created_by, 'created_at', t.created_at
  )
$$;

create or replace function _task_full(t tasks) returns jsonb
language sql stable security definer set search_path = public as $$
  select _task_summary(t) || jsonb_build_object(
    'context', t.context, 'data_intel', t.data_intel, 'wiki_page', t.wiki_page,
    'reference_docs', t.reference_docs, 'deliverable_spec', t.deliverable_spec,
    'skill_route', t.skill_route, 'voice_rules', t.voice_rules,
    'superseded_by', t.superseded_by
  )
$$;

-- Exit Gate rule 1: local paths are invisible to other agents and to Jack.
create or replace function _has_local_path(p text) returns boolean
language sql immutable as $$
  select p is not null and (
    p ~ '(/sessions/|/tmp/|/Users/|/var/folders/|/private/|file://)'
    or p ~ '^[~/]' and p !~ '^https?://'
  )
$$;

-- Lazy lease enforcement: expired leases return tasks to the pool, with an event.
create or replace function expire_leases() returns int
language plpgsql security definer set search_path = public as $$
declare r record; n int := 0;
begin
  for r in
    update tasks
    set claimed_by = null, lease_expires_at = null,
        state = case when state = 'in_production' then 'ready' else state end
    where lease_expires_at < now()
      and superseded_by is null
      and state not in ('done','cancelled')
    returning id, claimed_by, state
  loop
    perform _emit('system', 'task.lease_expired', 'task', r.id::text,
                  jsonb_build_object('state', r.state), 'standard');
    n := n + 1;
  end loop;
  return n;
end $$;

-------------------------------------------------------------------------------
-- agent + workflow + program
-------------------------------------------------------------------------------

create or replace function register_agent(p_agent_key text, p_capabilities text[] default null)
returns jsonb
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
    'my_claimed_tasks', (select coalesce(jsonb_agg(_task_summary(t)), '[]')
                         from tasks t where t.claimed_by = v_agent and t.superseded_by is null
                           and t.state not in ('done','cancelled')),
    'unclaimed_ready_for_me', (select count(*) from tasks t
                               where t.state = 'ready' and t.claimed_by is null and t.superseded_by is null
                                 and t.required_capabilities <@ v_row.capabilities),
    'open_requests_for_me', (select count(*) from data_requests
                             where status = 'open' and (fulfiller = v_agent or fulfiller is null) and requester <> v_agent)
  );
end $$;

create or replace function workflow_define(
  p_agent_key text, p_id text, p_states text[], p_transitions jsonb, p_version int default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_agent text; v_version int; v_state text;
begin
  v_agent := _auth_agent(p_agent_key);
  if array_length(p_states, 1) is null then
    raise exception 'states must be a non-empty array; the first state is the initial state for new tasks.';
  end if;
  for v_state in select jsonb_object_keys(p_transitions) loop
    if not v_state = any(p_states) then
      raise exception 'transitions references state "%" which is not in states %. Fix the transitions map.', v_state, p_states;
    end if;
  end loop;
  v_version := coalesce(p_version, (select coalesce(max(version), 0) + 1 from workflows where id = p_id));
  insert into workflows (id, version, states, transitions) values (p_id, v_version, p_states, p_transitions);
  perform _emit(v_agent, 'workflow.defined', 'workflow', p_id || ' v' || v_version,
                jsonb_build_object('states', p_states), 'standard');
  return jsonb_build_object('workflow_id', p_id, 'version', v_version, 'states', p_states);
end $$;

create or replace function program_create(p_agent_key text, p_program jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_agent text; v_row programs; v_wf_version int;
begin
  v_agent := _auth_agent(p_agent_key);
  if p_program->>'type' is null or p_program->>'name' is null or p_program->>'workflow_id' is null
     or p_program->>'owner_human' is null then
    raise exception 'program_create requires type, name, workflow_id, owner_human. Optional: workflow_version, config, source_ref.';
  end if;
  v_wf_version := coalesce((p_program->>'workflow_version')::int,
                           (select max(version) from workflows where id = p_program->>'workflow_id'));
  if v_wf_version is null then
    raise exception 'Unknown workflow "%". Define it first with workflow_define (states + transitions as data — no schema change needed).', p_program->>'workflow_id';
  end if;
  insert into programs (type, name, workflow_id, workflow_version, config, source_ref, owner_human)
  values (p_program->>'type', p_program->>'name', p_program->>'workflow_id', v_wf_version,
          coalesce(p_program->'config', '{}'), p_program->>'source_ref', p_program->>'owner_human')
  returning * into v_row;
  perform _emit(v_agent, 'program.created', 'program', v_row.id::text,
                jsonb_build_object('type', v_row.type, 'name', v_row.name), 'major');
  return jsonb_build_object('program_id', v_row.id, 'type', v_row.type, 'name', v_row.name,
                            'workflow', v_row.workflow_id || ' v' || v_row.workflow_version);
end $$;

create or replace function program_query(p_agent_key text, p_program_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_agent text; v_prog programs;
begin
  v_agent := _auth_agent(p_agent_key);
  select * into v_prog from programs where id = p_program_id;
  if not found then
    raise exception 'No program with id %. Use board_query to list active programs.', p_program_id;
  end if;
  return jsonb_build_object(
    'program', to_jsonb(v_prog),
    'tasks_by_state', coalesce((
      select jsonb_object_agg(state, items) from (
        select t.state, jsonb_agg(_task_summary(t) order by t.created_at) as items
        from tasks t where t.program_id = p_program_id and t.superseded_by is null
        group by t.state) s), '{}'),
    'open_decisions', coalesce((
      select jsonb_agg(jsonb_build_object('id', d.id, 'question', d.question, 'approver', d.approver,
               'opened_at', d.opened_at, 'age_hours', round(extract(epoch from now() - d.opened_at) / 3600, 1),
               'sla_hours', d.sla_hours, 'artifact_url', d.artifact_url, 'blocking_task_id', d.blocking_task_id))
      from decisions d join tasks t on t.id = d.blocking_task_id
      where t.program_id = p_program_id and d.resolved_at is null), '[]'),
    'recent_events', coalesce((
      select jsonb_agg(jsonb_build_object('ts', e.ts, 'actor', e.actor, 'verb', e.verb,
               'object_type', e.object_type, 'object_id', e.object_id, 'significance', e.significance))
      from (select * from events e
            where (e.object_type = 'program' and e.object_id = p_program_id::text)
               or (e.object_type = 'task' and e.object_id in
                   (select id::text from tasks where program_id = p_program_id))
            order by e.ts desc limit 50) e), '[]')
  );
end $$;

-------------------------------------------------------------------------------
-- tasks
-------------------------------------------------------------------------------

create or replace function task_create(p_agent_key text, p_task jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_agent text; v_row tasks; v_existing tasks; v_wf workflows;
  v_wf_id text; v_wf_version int; v_type text; v_priority text; v_output text;
begin
  v_agent := _auth_agent(p_agent_key);

  -- idempotent dispatch: same external_id returns the existing row, never an error
  if p_task->>'external_id' is not null then
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

  if p_task->>'program_id' is not null
     and not exists (select 1 from programs where id = (p_task->>'program_id')::uuid) then
    raise exception 'Unknown program_id %. Create the program first with program_create, or omit program_id for an ad-hoc task.', p_task->>'program_id';
  end if;

  insert into tasks (external_id, program_id, workflow_id, workflow_version, state,
    type, priority, deadline, context, data_intel, wiki_page, reference_docs,
    deliverable_spec, output_location, drive_folder, skill_route, voice_rules,
    required_capabilities, created_by)
  values (
    p_task->>'external_id', (p_task->>'program_id')::uuid, v_wf_id, v_wf_version, v_wf.states[1],
    v_type, v_priority, (p_task->>'deadline')::timestamptz,
    p_task->>'context', p_task->>'data_intel', p_task->>'wiki_page',
    case when p_task ? 'reference_docs' then array(select jsonb_array_elements_text(p_task->'reference_docs')) end,
    p_task->>'deliverable_spec', v_output, p_task->>'drive_folder',
    p_task->>'skill_route', p_task->>'voice_rules',
    coalesce(array(select jsonb_array_elements_text(p_task->'required_capabilities')), '{}'),
    v_agent)
  returning * into v_row;

  perform _emit(v_agent, 'task.created', 'task', v_row.id::text,
    jsonb_build_object('type', v_row.type, 'priority', v_row.priority,
      'deliverable_spec', left(v_row.deliverable_spec, 200), 'external_id', v_row.external_id,
      'required_capabilities', v_row.required_capabilities, 'deadline', v_row.deadline),
    case when v_row.priority in ('urgent','high') then 'major' else 'standard' end);

  return jsonb_build_object('task', _task_full(v_row), 'existing', false);
end $$;

create or replace function task_get(p_agent_key text, p_task_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_agent text; v_task tasks;
begin
  v_agent := _auth_agent(p_agent_key);
  select * into v_task from tasks where id = p_task_id;
  if not found then
    raise exception 'No task with id %. Use board_query to list open tasks.', p_task_id;
  end if;
  return jsonb_build_object(
    'task', _task_full(v_task),
    'deliverables', coalesce((select jsonb_agg(to_jsonb(d) order by d.version)
                              from deliverables d where d.task_id = p_task_id), '[]'),
    'decisions', coalesce((select jsonb_agg(to_jsonb(d) order by d.opened_at)
                           from decisions d where d.blocking_task_id = p_task_id), '[]'),
    'timeline', coalesce((select jsonb_agg(jsonb_build_object('ts', e.ts, 'actor', e.actor,
                            'verb', e.verb, 'payload', e.payload) order by e.ts)
                          from events e where e.object_type = 'task' and e.object_id = p_task_id::text), '[]')
  );
end $$;

create or replace function task_claim(p_agent_key text, p_task_id uuid, p_ttl_minutes int default 240)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_agent text; v_task tasks; v_caps text[]; v_missing text[];
  v_prev_owner text; v_prev_lease timestamptz; v_row tasks; v_renewal boolean;
begin
  v_agent := _auth_agent(p_agent_key);
  select * into v_task from tasks where id = p_task_id;
  if not found then
    raise exception 'No task with id %. Use board_query to find the task you mean.', p_task_id;
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
  if not (v_task.required_capabilities <@ v_caps) then
    select array(select unnest(v_task.required_capabilities) except select unnest(v_caps)) into v_missing;
    return jsonb_build_object('claimed', false, 'reason', 'missing_capabilities',
      'missing', v_missing,
      'message', 'You lack required capabilities ' || v_missing::text || '. Leave this task for an agent that has them, or ask Jack to extend your capabilities.');
  end if;

  v_prev_owner := v_task.claimed_by;
  v_prev_lease := v_task.lease_expires_at;
  v_renewal := coalesce(v_prev_owner = v_agent, false);

  -- the atomic claim: exactly one concurrent caller can win this UPDATE
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
                jsonb_build_object('lease_expires_at', v_row.lease_expires_at),
                case when v_renewal then 'routine' else 'standard' end);

  return jsonb_build_object('claimed', true, 'renewal', v_renewal, 'task', _task_full(v_row));
end $$;

create or replace function task_release(p_agent_key text, p_task_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_agent text; v_task tasks;
begin
  v_agent := _auth_agent(p_agent_key);
  select * into v_task from tasks where id = p_task_id;
  if not found then
    raise exception 'No task with id %.', p_task_id;
  end if;
  if v_task.claimed_by is distinct from v_agent then
    raise exception 'You do not hold this task (owner: %). Only the claimant can release it.', coalesce(v_task.claimed_by, 'nobody');
  end if;
  update tasks
  set claimed_by = null, lease_expires_at = null,
      state = case when state = 'in_production' then 'ready' else state end
  where id = p_task_id
  returning * into v_task;
  perform _emit(v_agent, 'task.released', 'task', p_task_id::text,
                jsonb_build_object('state', v_task.state), 'standard');
  return jsonb_build_object('released', true, 'state', v_task.state);
end $$;

create or replace function task_transition(p_agent_key text, p_task_id uuid, p_to_state text, p_note text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_agent text; v_task tasks; v_wf workflows; v_legal text[]; v_from text;
begin
  v_agent := _auth_agent(p_agent_key);
  select * into v_task from tasks where id = p_task_id;
  if not found then
    raise exception 'No task with id %.', p_task_id;
  end if;
  if v_task.superseded_by is not null then
    raise exception 'Task was superseded by %. Transition the replacement instead.', v_task.superseded_by;
  end if;
  if v_task.claimed_by is not null and v_task.claimed_by <> v_agent then
    raise exception 'Task is claimed by %. Only the claimant transitions a claimed task; coordinate with the owner.', v_task.claimed_by;
  end if;
  if p_to_state = 'done' then
    raise exception 'Use task_complete to finish a task — it enforces the Exit Gate and records the deliverable.';
  end if;

  select * into v_wf from workflows where id = v_task.workflow_id and version = v_task.workflow_version;
  v_legal := coalesce(array(select jsonb_array_elements_text(v_wf.transitions->v_task.state)), '{}');
  if not p_to_state = any(v_legal) then
    raise exception 'Illegal transition % -> % for workflow % v%. Legal next states from "%": %.',
      v_task.state, p_to_state, v_task.workflow_id, v_task.workflow_version, v_task.state, v_legal;
  end if;

  v_from := v_task.state;
  update tasks set state = p_to_state where id = p_task_id;
  perform _emit(v_agent, 'task.transitioned', 'task', p_task_id::text,
                jsonb_build_object('from', v_from, 'to', p_to_state, 'note', p_note),
                'standard');
  return jsonb_build_object('task_id', p_task_id, 'from', v_from, 'state', p_to_state);
end $$;

create or replace function task_complete(
  p_agent_key text, p_task_id uuid,
  p_drive_url text default null, p_inline_content text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_agent text; v_task tasks; v_version int; v_deliv deliverables; v_done_state text;
begin
  v_agent := _auth_agent(p_agent_key);
  select * into v_task from tasks where id = p_task_id;
  if not found then
    raise exception 'No task with id %.', p_task_id;
  end if;
  if v_task.superseded_by is not null then
    raise exception 'Task was superseded by %. Do not complete a superseded task; complete the replacement.', v_task.superseded_by;
  end if;
  if v_task.state = 'done' then
    return jsonb_build_object('completed', false, 'notice', 'Task is already done. Existing deliverables: ' ||
      (select count(*) from deliverables where task_id = p_task_id) || '. To ship a revision, supersede the task or attach a new version via a new task.');
  end if;
  if v_task.claimed_by is null then
    raise exception 'Claim the task first (task_claim) so ownership is recorded, then complete it.';
  end if;
  if v_task.claimed_by <> v_agent then
    raise exception 'Task is claimed by %. Only the claimant can complete it; coordinate with the owner.', v_task.claimed_by;
  end if;

  -- Exit Gate rule 1: local paths never count as proof.
  if _has_local_path(p_drive_url) or _has_local_path(p_inline_content) then
    raise exception 'Local paths are invisible to DAO and Jack. Save to the shared Drive and pass the URL.';
  end if;

  -- Exit Gate rule 2: proof must match the task's output_location.
  if v_task.output_location = 'drive' then
    if p_drive_url is null or p_drive_url !~ '^https://(docs|drive)\.google\.com/' then
      raise exception 'This task requires a Google Drive deliverable. Save the file to the Cowork-Shared drive (folder 1oC9T-mavIw0z5amkDMWiHlvxsux_6hzf) and pass the docs.google.com or drive.google.com URL as drive_url.';
    end if;
  elsif v_task.output_location = 'thread' then
    if coalesce(p_inline_content, '') = '' then
      raise exception 'This task''s output_location is "thread": pass the full deliverable text as inline_content.';
    end if;
  elsif v_task.output_location = 'workspace' then
    if coalesce(p_inline_content, '') = '' then
      raise exception 'This task''s output_location is "workspace": pass the workspace-relative path (e.g. "deliverables/qualification/x.docx") as inline_content. Absolute local paths are rejected.';
    end if;
  end if;

  select coalesce(max(version), 0) + 1 into v_version from deliverables where task_id = p_task_id;
  insert into deliverables (task_id, version, drive_url, inline_content, produced_by)
  values (p_task_id, v_version, p_drive_url, p_inline_content, v_agent)
  returning * into v_deliv;

  select case when 'done' = any(states) then 'done' else states[array_upper(states, 1)] end
  into v_done_state from workflows
  where id = v_task.workflow_id and version = v_task.workflow_version;

  update tasks set state = v_done_state, lease_expires_at = null where id = p_task_id;

  perform _emit(v_agent, 'task.completed', 'task', p_task_id::text,
    jsonb_build_object('deliverable_id', v_deliv.id, 'version', v_version,
      'drive_url', p_drive_url, 'type', v_task.type,
      'deliverable_spec', left(v_task.deliverable_spec, 200)), 'major');

  return jsonb_build_object('completed', true, 'state', v_done_state,
    'deliverable', jsonb_build_object('id', v_deliv.id, 'version', v_version, 'drive_url', p_drive_url));
end $$;

create or replace function task_supersede(p_agent_key text, p_old_task_id uuid, p_overrides jsonb default '{}')
returns jsonb
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

  -- build the replacement: old fields merged with overrides (overrides win)
  v_spec := (_task_full(v_old)
              - 'id' - 'external_id' - 'state' - 'claimed_by' - 'lease_expires_at'
              - 'supersedes_id' - 'superseded_by' - 'created_by' - 'created_at' - 'workflow')
            || jsonb_build_object('workflow_id', v_old.workflow_id, 'workflow_version', v_old.workflow_version)
            || coalesce(p_overrides, '{}');

  v_new := null;
  select * into v_new from jsonb_populate_record(null::tasks,
            (select (task_create(p_agent_key, v_spec))->'task'));
  -- task_create emitted task.created; now wire the chain
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
-- decisions + data requests
-------------------------------------------------------------------------------

create or replace function decision_open(
  p_agent_key text, p_question text, p_approver text,
  p_options jsonb default null, p_default_action text default null,
  p_blocking_task_id uuid default null, p_artifact_url text default null,
  p_sla_hours int default 24
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_agent text; v_row decisions;
begin
  v_agent := _auth_agent(p_agent_key);
  if coalesce(p_question, '') = '' then
    raise exception 'question is required: state the decision the human must make, in one sentence.';
  end if;
  if p_blocking_task_id is not null and not exists (select 1 from tasks where id = p_blocking_task_id) then
    raise exception 'No task with id % to block on.', p_blocking_task_id;
  end if;
  if p_artifact_url is not null and _has_local_path(p_artifact_url) then
    raise exception 'Local paths are invisible to the approver. Share the artifact on Drive and pass that URL.';
  end if;

  insert into decisions (question, options, default_action, approver, blocking_task_id,
                         artifact_url, sla_hours, opened_by)
  values (p_question, p_options, p_default_action, p_approver, p_blocking_task_id,
          p_artifact_url, p_sla_hours, v_agent)
  returning * into v_row;

  if p_blocking_task_id is not null then
    update tasks set state = 'blocked'
    where id = p_blocking_task_id and state not in ('done','cancelled','blocked');
  end if;

  perform _emit(v_agent, 'decision.opened', 'decision', v_row.id::text,
    jsonb_build_object('question', p_question, 'approver', p_approver,
      'sla_hours', p_sla_hours, 'artifact_url', p_artifact_url,
      'blocking_task_id', p_blocking_task_id), 'major');

  return jsonb_build_object('decision_id', v_row.id, 'approver', p_approver,
    'sla_deadline', v_row.opened_at + make_interval(hours => p_sla_hours));
end $$;

create or replace function decision_resolve(
  p_agent_key text, p_decision_id uuid, p_resolution text, p_resolved_by text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_agent text; v_row decisions; v_task tasks;
begin
  v_agent := _auth_agent(p_agent_key);
  select * into v_row from decisions where id = p_decision_id;
  if not found then
    raise exception 'No decision with id %. Use board_query to list open decisions.', p_decision_id;
  end if;
  if v_row.resolved_at is not null then
    return jsonb_build_object('resolved', false,
      'notice', 'Decision was already resolved by ' || v_row.resolved_by || ' at ' || v_row.resolved_at ||
                ' (resolution: ' || v_row.resolution || '). No action taken.');
  end if;

  update decisions
  set resolved_at = now(), resolved_by = coalesce(p_resolved_by, v_agent), resolution = p_resolution
  where id = p_decision_id
  returning * into v_row;

  if v_row.blocking_task_id is not null then
    select * into v_task from tasks where id = v_row.blocking_task_id;
    if v_task.superseded_by is not null then
      perform _emit(v_agent, 'decision.resolved', 'decision', p_decision_id::text,
        jsonb_build_object('resolution', p_resolution, 'notice', 'blocking task was superseded; nothing to unblock'), 'major');
      return jsonb_build_object('resolved', true,
        'notice', 'Resolved, but the blocking task was superseded meanwhile — nothing to unblock.');
    end if;
    update tasks set state = 'ready' where id = v_row.blocking_task_id and state = 'blocked';
  end if;

  perform _emit(v_agent, 'decision.resolved', 'decision', p_decision_id::text,
    jsonb_build_object('resolution', p_resolution, 'resolved_by', v_row.resolved_by,
      'unblocked_task_id', v_row.blocking_task_id), 'major');

  return jsonb_build_object('resolved', true, 'resolution', p_resolution,
    'unblocked_task_id', v_row.blocking_task_id);
end $$;

create or replace function request_open(
  p_agent_key text, p_type text, p_request text,
  p_context text default null, p_fulfiller text default null,
  p_requires_approval boolean default false
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_agent text; v_row data_requests;
begin
  v_agent := _auth_agent(p_agent_key);
  if p_fulfiller is not null and not exists (select 1 from agents where id = p_fulfiller and status = 'active') then
    raise exception 'No active agent "%" to fulfill this. Omit fulfiller to let any agent pick it up.', p_fulfiller;
  end if;
  insert into data_requests (requester, fulfiller, type, request, context, requires_approval)
  values (v_agent, p_fulfiller, p_type, p_request, p_context, p_requires_approval)
  returning * into v_row;
  perform _emit(v_agent, 'request.opened', 'data_request', v_row.id::text,
    jsonb_build_object('type', p_type, 'request', left(p_request, 200),
      'fulfiller', p_fulfiller, 'requires_approval', p_requires_approval), 'standard');
  return jsonb_build_object('request_id', v_row.id, 'status', 'open');
end $$;

create or replace function request_fulfill(
  p_agent_key text, p_request_id uuid, p_payload jsonb default null,
  p_status text default 'fulfilled'
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_agent text; v_row data_requests;
begin
  v_agent := _auth_agent(p_agent_key);
  if p_status not in ('fulfilled','declined') then
    raise exception 'status must be fulfilled or declined.';
  end if;
  select * into v_row from data_requests where id = p_request_id;
  if not found then
    raise exception 'No data request with id %.', p_request_id;
  end if;
  if v_row.status <> 'open' then
    return jsonb_build_object('fulfilled', false,
      'notice', 'Request is already ' || v_row.status || '. No action taken.');
  end if;
  update data_requests
  set status = p_status, fulfiller = v_agent,
      fulfilled_payload = p_payload, fulfilled_at = now()
  where id = p_request_id;
  perform _emit(v_agent, 'request.fulfilled', 'data_request', p_request_id::text,
    jsonb_build_object('status', p_status, 'requester', v_row.requester), 'standard');
  return jsonb_build_object('fulfilled', p_status = 'fulfilled', 'status', p_status,
    'requester', v_row.requester);
end $$;

-------------------------------------------------------------------------------
-- crons
-------------------------------------------------------------------------------

create or replace function cron_register(
  p_agent_key text, p_cron_id text, p_schedule text, p_expected_interval_minutes int
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_agent text;
begin
  v_agent := _auth_agent(p_agent_key);
  insert into crons (id, owner_agent, schedule, expected_interval_minutes)
  values (p_cron_id, v_agent, p_schedule, p_expected_interval_minutes)
  on conflict (id) do update
    set schedule = excluded.schedule,
        expected_interval_minutes = excluded.expected_interval_minutes,
        status = 'active';
  perform _emit(v_agent, 'cron.registered', 'cron', p_cron_id,
    jsonb_build_object('schedule', p_schedule, 'expected_interval_minutes', p_expected_interval_minutes), 'standard');
  return jsonb_build_object('cron_id', p_cron_id, 'registered', true);
end $$;

create or replace function cron_heartbeat(
  p_agent_key text, p_cron_id text, p_status text default 'ok', p_note text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_agent text;
begin
  v_agent := _auth_agent(p_agent_key);
  if not exists (select 1 from crons where id = p_cron_id) then
    raise exception 'Unknown cron_id "%". Register it first: cron_register(cron_id, schedule, expected_interval_minutes). Known crons are listed in board_query under cron_health.', p_cron_id;
  end if;
  if p_status not in ('ok','failed') then
    raise exception 'status must be ok or failed.';
  end if;
  insert into cron_runs (cron_id, status, note) values (p_cron_id, p_status, p_note);
  perform _emit(v_agent, 'cron.heartbeat', 'cron', p_cron_id,
    jsonb_build_object('status', p_status, 'note', p_note),
    case when p_status = 'failed' then 'standard' else 'routine' end);
  return jsonb_build_object('cron_id', p_cron_id, 'recorded', true);
end $$;

-------------------------------------------------------------------------------
-- reads: board, pulse, generic event append
-------------------------------------------------------------------------------

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
      from programs p where p.status = 'active'), '[]')
  );
end $$;

create or replace function pulse_query(
  p_agent_key text, p_from timestamptz default date_trunc('day', now()), p_to timestamptz default now()
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_agent text;
begin
  v_agent := _auth_agent(p_agent_key);
  return jsonb_build_object(
    'from', p_from, 'to', p_to,
    'events', coalesce((
      select jsonb_object_agg(significance, items) from (
        select e.significance, jsonb_agg(jsonb_build_object('ts', e.ts, 'actor', e.actor,
            'verb', e.verb, 'object_type', e.object_type, 'object_id', e.object_id,
            'payload', e.payload) order by e.ts) as items
        from (select * from events where ts >= p_from and ts < p_to order by ts limit 1000) e
        group by e.significance) s), '{}'),
    'completed_deliverables', coalesce((
      select jsonb_agg(jsonb_build_object('task_id', d.task_id, 'version', d.version,
          'drive_url', d.drive_url, 'produced_by', d.produced_by, 'completed_at', d.completed_at,
          'spec', left(t.deliverable_spec, 150)) order by d.completed_at)
      from deliverables d join tasks t on t.id = d.task_id
      where d.completed_at >= p_from and d.completed_at < p_to), '[]'),
    'blocked_now', jsonb_build_object(
      'decisions', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'approver', d.approver,
          'question', d.question, 'age_hours', round(extract(epoch from now() - d.opened_at) / 3600, 1),
          'escalated', d.escalated_at is not null) order by d.opened_at)
        from decisions d where d.resolved_at is null), '[]'),
      'tasks', coalesce((select jsonb_agg(jsonb_build_object('id', t.id,
          'spec', left(t.deliverable_spec, 150),
          'age_hours', round(extract(epoch from now() - t.created_at) / 3600, 1)) order by t.created_at)
        from tasks t where t.state = 'blocked' and t.superseded_by is null), '[]'))
  );
end $$;

create or replace function event_append(
  p_agent_key text, p_verb text, p_object_type text, p_object_id text,
  p_payload jsonb default '{}', p_significance text default 'standard',
  p_idempotency_key text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_agent text;
begin
  v_agent := _auth_agent(p_agent_key);
  if p_significance not in ('major','standard','routine') then
    raise exception 'significance must be major, standard, or routine.';
  end if;
  return _emit(v_agent, p_verb, p_object_type, p_object_id, p_payload, p_significance, p_idempotency_key);
end $$;

-------------------------------------------------------------------------------
-- sla_check: called by pg_cron every 15 min (wired in 0004)
-------------------------------------------------------------------------------

create or replace function sla_check() returns jsonb
language plpgsql security definer set search_path = public as $$
declare r record; v_escalated int := 0; v_expired int;
begin
  v_expired := expire_leases();
  for r in
    update decisions set escalated_at = now()
    where resolved_at is null and escalated_at is null
      and opened_at + make_interval(hours => sla_hours) < now()
    returning id, approver, question, opened_at, sla_hours
  loop
    perform _emit('system', 'decision.escalated', 'decision', r.id::text,
      jsonb_build_object('approver', r.approver, 'question', r.question,
        'age_hours', round(extract(epoch from now() - r.opened_at) / 3600, 1),
        'sla_hours', r.sla_hours), 'major');
    v_escalated := v_escalated + 1;
  end loop;
  return jsonb_build_object('escalated', v_escalated, 'leases_expired', v_expired);
end $$;

-------------------------------------------------------------------------------
-- grants: tools are callable by anon (they self-authenticate via agent key);
-- helpers are not.
-------------------------------------------------------------------------------

revoke execute on all functions in schema public from public, anon, authenticated;

grant execute on function
  register_agent(text, text[]),
  workflow_define(text, text, text[], jsonb, int),
  program_create(text, jsonb),
  program_query(text, uuid),
  task_create(text, jsonb),
  task_get(text, uuid),
  task_claim(text, uuid, int),
  task_release(text, uuid),
  task_transition(text, uuid, text, text),
  task_complete(text, uuid, text, text),
  task_supersede(text, uuid, jsonb),
  decision_open(text, text, text, jsonb, text, uuid, text, int),
  decision_resolve(text, uuid, text, text),
  request_open(text, text, text, text, text, boolean),
  request_fulfill(text, uuid, jsonb, text),
  cron_register(text, text, text, int),
  cron_heartbeat(text, text, text, text),
  board_query(text),
  pulse_query(text, timestamptz, timestamptz),
  event_append(text, text, text, text, jsonb, text, text),
  sla_check()
to anon, authenticated;
