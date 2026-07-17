-- Backbone 0006 — two improvements:
-- 1. pulse_query: include inline_content in completed_deliverables so the board
--    can show workspace-path deliverables without a separate task_get call.
-- 2. board_query: include drive_url and inline_content on tasks_by_state rows
--    so task cards can render deliverable links without a second round-trip.

-- ── pulse_query: add inline_content ──────────────────────────────────────────
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
        select e.significance, jsonb_agg(jsonb_build_object(
            'ts', e.ts, 'actor', e.actor, 'verb', e.verb,
            'object_type', e.object_type, 'object_id', e.object_id,
            'payload', e.payload) order by e.ts) as items
        from (select * from events where ts >= p_from and ts < p_to order by ts limit 1000) e
        group by e.significance) s), '{}'),
    'completed_deliverables', coalesce((
      select jsonb_agg(jsonb_build_object(
          'task_id',       d.task_id,
          'version',       d.version,
          'drive_url',     d.drive_url,
          'inline_content', d.inline_content,   -- NEW: workspace path or thread text
          'produced_by',   d.produced_by,
          'completed_at',  d.completed_at,
          'spec',          left(t.deliverable_spec, 150)) order by d.completed_at)
      from deliverables d join tasks t on t.id = d.task_id
      where d.completed_at >= p_from and d.completed_at < p_to), '[]'),
    'blocked_now', jsonb_build_object(
      'decisions', coalesce((select jsonb_agg(jsonb_build_object(
          'id', d.id, 'approver', d.approver, 'question', d.question,
          'age_hours', round(extract(epoch from now() - d.opened_at) / 3600, 1),
          'escalated', d.escalated_at is not null,
          'blocking_task_id', d.blocking_task_id) order by d.opened_at)
        from decisions d where d.resolved_at is null), '[]'),
      'tasks', coalesce((select jsonb_agg(jsonb_build_object(
          'id', t.id, 'spec', left(t.deliverable_spec, 150),
          'age_hours', round(extract(epoch from now() - t.created_at) / 3600, 1)) order by t.created_at)
        from tasks t where t.state = 'blocked' and t.superseded_by is null), '[]'))
  );
end $$;

-- ── _task_full: add latest_deliverable for board card rendering ───────────────
-- _task_full is what board_query and task_get expose per task.
-- Add drive_url + inline_content from the most recent deliverable so task cards
-- can show a link without a separate round-trip.
create or replace function _task_full(t tasks) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'id',                  t.id,
    'external_id',         t.external_id,
    'program_id',          t.program_id,
    'state',               t.state,
    'type',                t.type,
    'priority',            t.priority,
    'workflow',            t.workflow_id || ' v' || t.workflow_version,
    'deadline',            t.deadline,
    'context',             t.context,
    'data_intel',          t.data_intel,
    'wiki_page',           t.wiki_page,
    'reference_docs',      t.reference_docs,
    'deliverable_spec',    t.deliverable_spec,
    'output_location',     t.output_location,
    'drive_folder',        t.drive_folder,
    'skill_route',         t.skill_route,
    'voice_rules',         t.voice_rules,
    'required_capabilities', t.required_capabilities,
    'created_by',          t.created_by,
    'claimed_by',          t.claimed_by,
    'created_at',          t.created_at,
    'lease_expires_at',    t.lease_expires_at,
    'supersedes_id',       t.supersedes_id,
    'superseded_by',       t.superseded_by,
    -- NEW: latest deliverable link for card rendering
    'latest_drive_url',    (select drive_url from deliverables
                            where task_id = t.id order by version desc limit 1),
    'latest_inline',       (select inline_content from deliverables
                            where task_id = t.id order by version desc limit 1)
  )
$$;
