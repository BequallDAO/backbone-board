-- Backbone 0002 — seed data: agents, default workflow, known crons.

insert into agents (id, human_owner, capabilities) values
  ('dao',         'jack', '{orchestration,data_query,signal_scan,city_lookup,write_back,wiki_path,research,slack}'),
  ('cowork',      'jack', '{docx,xlsx,document,proposal,email,analysis,research,sequence}'),
  ('claude-code', 'jack', '{code,migration,analysis,research}');

insert into workflows (id, version, states, transitions) values (
  'default', 1,
  '{ready,in_production,blocked,done,cancelled}',
  '{
    "ready":         ["in_production", "blocked", "cancelled"],
    "in_production": ["ready", "blocked", "done", "cancelled"],
    "blocked":       ["ready", "in_production", "cancelled"],
    "done":          [],
    "cancelled":     []
  }'::jsonb
);

-- Existing scheduled jobs (registry seeded from the live operating rhythm;
-- heartbeats make this truth from cutover onward).
insert into crons (id, owner_agent, schedule, expected_interval_minutes) values
  ('morning-briefing',      'dao',    '15 8 * * 1-5',  1440),
  ('autonomous-execution',  'dao',    '0 10 * * 1-5',  1440),
  ('team-call-summary',     'dao',    '0 15 * * 1,4',  4320),
  ('weekly-synthesis',      'dao',    '0 16 * * 5',   10080),
  ('grain-daily-rag-review','dao',    '0 18 * * 1-5',  1440),
  ('weekly-digest',         'dao',    '0 9 * * 1',    10080),
  ('cowork-pulse',          'cowork', '0 */4 * * *',    240);
