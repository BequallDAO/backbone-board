-- Backbone 0001 — core schema
-- Substrate tables only. Domain policy lives in programs.config and workflows rows,
-- never in this schema (the fourth-program test depends on it).

create extension if not exists pgcrypto with schema extensions;

-- agents: identity as data. Adding an agent = insert + key, never a code change.
create table agents (
  id             text primary key,             -- 'dao', 'cowork', 'claude-code', 'scott-cowork'
  human_owner    text not null,                -- 'jack', 'scott', 'kevin', 'tucker'
  capabilities   text[] not null default '{}', -- e.g. '{docx,proposal,research,sales}'
  status         text not null default 'active' check (status in ('active','paused','retired')),
  last_heartbeat timestamptz,
  created_at     timestamptz not null default now()
);

-- agent_keys: sha256 hashes of per-agent API keys. Plaintext never stored.
create table agent_keys (
  key_hash   text primary key,
  agent_id   text not null references agents(id),
  label      text,
  created_at timestamptz not null default now(),
  revoked_at timestamptz
);

-- workflows: typed state machines as data. Versioned; in-flight tasks finish on their version.
create table workflows (
  id          text not null,                 -- 'default', 'engagement-runtime', 'ai-sales'
  version     int  not null default 1,
  states      text[] not null,
  transitions jsonb not null,                -- {"ready":["in_production"], ...}
  created_at  timestamptz not null default now(),
  primary key (id, version)
);

-- programs: one row per running loop (an engagement, a deal, a campaign).
create table programs (
  id          uuid primary key default gen_random_uuid(),
  type        text not null,                 -- 'engagement' | 'ai-deal' | 'modular-deal' | 'campaign'
  name        text not null,
  workflow_id text not null,
  workflow_version int not null default 1,
  config      jsonb not null default '{}',   -- WIP limits, cadence, gates. Governor workers READ this.
  source_ref  text,
  owner_human text not null,
  status      text not null default 'active' check (status in ('active','paused','closed')),
  created_at  timestamptz not null default now()
);

-- tasks: the work items. Carries every field of the legacy DAO-TASK message format.
create table tasks (
  id            uuid primary key default gen_random_uuid(),
  external_id   text unique,                 -- idempotency for dispatch retries
  program_id    uuid references programs(id),
  workflow_id   text not null default 'default',
  workflow_version int not null default 1,
  state         text not null default 'ready',
  -- legacy DAO-TASK fields:
  type          text not null,               -- document|email|analysis|research|sequence|proposal|other
  priority      text not null default 'medium' check (priority in ('urgent','high','medium','low')),
  deadline      timestamptz,
  context       text,
  data_intel    text,
  wiki_page     text,
  reference_docs text[],
  deliverable_spec text not null,
  output_location text not null default 'drive' check (output_location in ('drive','workspace','thread')),
  drive_folder  text,
  skill_route   text,
  voice_rules   text,
  -- coordination fields:
  required_capabilities text[] not null default '{}',
  claimed_by    text references agents(id),
  lease_expires_at timestamptz,
  supersedes_id uuid references tasks(id),
  superseded_by uuid references tasks(id),   -- denormalized head pointer; heads have NULL here
  created_by    text not null references agents(id),
  created_at    timestamptz not null default now()
);
create index on tasks (state) where superseded_by is null;
create index on tasks (claimed_by) where claimed_by is not null;
create index on tasks (program_id) where program_id is not null;

-- deliverables: durable register of what shipped.
create table deliverables (
  id          uuid primary key default gen_random_uuid(),
  task_id     uuid not null references tasks(id),
  version     int not null default 1,
  drive_url   text,
  inline_content text,
  produced_by text not null references agents(id),
  completed_at timestamptz not null default now(),
  created_at  timestamptz not null default now(),
  unique (task_id, version)
);

-- decisions: the blocked-on-human queue. With artifact attached = the review queue.
create table decisions (
  id            uuid primary key default gen_random_uuid(),
  question      text not null,
  options       jsonb,
  default_action text,
  approver      text not null,               -- human id, not agent
  blocking_task_id uuid references tasks(id),
  artifact_url  text,
  sla_hours     int not null default 24,
  opened_by     text not null references agents(id),
  opened_at     timestamptz not null default now(),
  resolved_at   timestamptz,
  resolved_by   text,
  resolution    text,
  escalated_at  timestamptz,
  created_at    timestamptz not null default now()
);
create index on decisions (approver) where resolved_at is null;

-- data_requests: replaces the Slack wait-protocol.
create table data_requests (
  id            uuid primary key default gen_random_uuid(),
  requester     text not null references agents(id),
  fulfiller     text references agents(id),
  type          text not null,               -- data_query|signal_scan|city_lookup|write_back|wiki_path
  request       text not null,
  context       text,
  requires_approval boolean not null default false,
  status        text not null default 'open' check (status in ('open','fulfilled','declined')),
  fulfilled_payload jsonb,
  fulfilled_at  timestamptz,
  created_at    timestamptz not null default now()
);

-- crons + cron_runs: the registry becomes truth via heartbeats.
create table crons (
  id            text primary key,
  owner_agent   text not null references agents(id),
  schedule      text not null,               -- cron expression, documentation only
  expected_interval_minutes int not null,
  status        text not null default 'active',
  created_at    timestamptz not null default now()
);
create table cron_runs (
  id          uuid primary key default gen_random_uuid(),
  cron_id     text not null references crons(id),
  ran_at      timestamptz not null default now(),
  status      text not null default 'ok' check (status in ('ok','failed')),
  note        text,
  created_at  timestamptz not null default now()
);
create index on cron_runs (cron_id, ran_at desc);

-- events: append-only log. NEVER updated or deleted.
create table events (
  id          bigint generated always as identity primary key,
  idempotency_key text unique,
  actor       text not null,
  verb        text not null,
  object_type text not null,
  object_id   text not null,
  payload     jsonb not null default '{}',
  significance text not null default 'standard' check (significance in ('major','standard','routine')),
  ts          timestamptz not null default now()
);
create index on events (ts);
create index on events (object_type, object_id);

-- app_config: private key/value for notifier wiring. Service-role / definer access only.
create table app_config (
  key        text primary key,
  value      text not null,
  created_at timestamptz not null default now()
);

-- Lock everything down. Agents and humans never touch tables directly;
-- all writes flow through security-definer functions (migration 0003).
alter table agents        enable row level security;
alter table agent_keys    enable row level security;
alter table workflows     enable row level security;
alter table programs      enable row level security;
alter table tasks         enable row level security;
alter table deliverables  enable row level security;
alter table decisions     enable row level security;
alter table data_requests enable row level security;
alter table crons         enable row level security;
alter table cron_runs     enable row level security;
alter table events        enable row level security;
alter table app_config    enable row level security;

revoke all on all tables in schema public from anon, authenticated;
