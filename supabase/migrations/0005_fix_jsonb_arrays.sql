-- Backbone 0005 — task_create: tolerate JSON null for array fields.
-- task_supersede round-trips a task through _task_full, which serializes null
-- reference_docs/required_capabilities as JSON null; jsonb_array_elements_text
-- on a scalar raised "cannot extract elements from a scalar".

create or replace function _jsonb_text_array(p jsonb) returns text[]
language sql immutable as $$
  select case when jsonb_typeof(p) = 'array'
    then array(select jsonb_array_elements_text(p)) end
$$;

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
    _jsonb_text_array(p_task->'reference_docs'),
    p_task->>'deliverable_spec', v_output, p_task->>'drive_folder',
    p_task->>'skill_route', p_task->>'voice_rules',
    coalesce(_jsonb_text_array(p_task->'required_capabilities'), '{}'),
    v_agent)
  returning * into v_row;

  perform _emit(v_agent, 'task.created', 'task', v_row.id::text,
    jsonb_build_object('type', v_row.type, 'priority', v_row.priority,
      'deliverable_spec', left(v_row.deliverable_spec, 200), 'external_id', v_row.external_id,
      'required_capabilities', v_row.required_capabilities, 'deadline', v_row.deadline),
    case when v_row.priority in ('urgent','high') then 'major' else 'standard' end);

  return jsonb_build_object('task', _task_full(v_row), 'existing', false);
end $$;
