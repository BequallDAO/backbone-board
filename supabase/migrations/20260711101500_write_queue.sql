-- Backbone BLD-201 — persistent write queue with lease, ack, retry, and exception path.
-- Standalone migration: all agent writes still flow through security-definer RPCs.

create table if not exists write_queue_items (
  id                uuid primary key default gen_random_uuid(),
  queue_name        text not null default 'default',
  idempotency_key   text not null unique,
  payload           jsonb not null,
  status            text not null default 'queued'
                    check (status in ('queued','leased','acked','dead_letter')),
  retry_count       int not null default 0 check (retry_count >= 0),
  max_retries       int not null default 3 check (max_retries >= 0 and max_retries <= 10),
  available_at      timestamptz not null default now(),
  leased_by         text references agents(id),
  lease_expires_at  timestamptz,
  last_error        text,
  ack_result        jsonb,
  acked_at          timestamptz,
  dead_lettered_at  timestamptz,
  created_by        text not null references agents(id),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

create index if not exists write_queue_items_ready_idx
  on write_queue_items (queue_name, available_at, created_at)
  where status = 'queued';

create index if not exists write_queue_items_lease_idx
  on write_queue_items (lease_expires_at)
  where status = 'leased';

create table if not exists write_queue_exceptions (
  id                uuid primary key default gen_random_uuid(),
  write_queue_id    uuid not null unique references write_queue_items(id),
  queue_name        text not null,
  idempotency_key   text not null,
  payload           jsonb not null,
  retry_count       int not null,
  max_retries       int not null,
  last_error        text,
  created_by        text not null references agents(id),
  dead_lettered_by  text not null references agents(id),
  created_at        timestamptz not null default now()
);

alter table write_queue_items enable row level security;
alter table write_queue_exceptions enable row level security;
revoke all on write_queue_items, write_queue_exceptions from anon, authenticated;

create or replace function _write_queue_backoff_seconds(p_retry_number int)
returns int
language sql immutable as $$
  select case
    when p_retry_number <= 1 then 60
    when p_retry_number = 2 then 300
    else 900
  end
$$;

create or replace function _write_queue_summary(q write_queue_items)
returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'id', q.id,
    'queue_name', q.queue_name,
    'idempotency_key', q.idempotency_key,
    'payload', q.payload,
    'status', q.status,
    'retry_count', q.retry_count,
    'max_retries', q.max_retries,
    'available_at', q.available_at,
    'leased_by', q.leased_by,
    'lease_expires_at', q.lease_expires_at,
    'last_error', q.last_error,
    'ack_result', q.ack_result,
    'acked_at', q.acked_at,
    'dead_lettered_at', q.dead_lettered_at,
    'created_by', q.created_by,
    'created_at', q.created_at,
    'updated_at', q.updated_at
  )
$$;

create or replace function _write_queue_expire_leases()
returns int
language plpgsql security definer set search_path = public as $$
declare
  r record;
  n int := 0;
begin
  for r in
    update write_queue_items
    set status = 'queued',
        leased_by = null,
        lease_expires_at = null,
        updated_at = now()
    where status = 'leased'
      and lease_expires_at <= now()
    returning id, queue_name, idempotency_key
  loop
    perform _emit('system', 'write_queue.lease_expired', 'write_queue', r.id::text,
      jsonb_build_object('queue_name', r.queue_name, 'idempotency_key', r.idempotency_key), 'standard');
    n := n + 1;
  end loop;
  return n;
end $$;

create or replace function write_queue_enqueue(
  p_agent_key text,
  p_idempotency_key text,
  p_payload jsonb,
  p_queue_name text default 'default',
  p_available_at timestamptz default null,
  p_max_retries int default 3
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_agent text;
  v_row write_queue_items;
begin
  v_agent := _auth_agent(p_agent_key);
  if coalesce(p_idempotency_key, '') = '' then
    raise exception 'idempotency_key is required so queued writes can survive retries without duplicate downstream writes.';
  end if;
  if p_payload is null then
    raise exception 'payload is required: pass the downstream write request as JSON.';
  end if;
  if coalesce(p_queue_name, '') = '' then
    raise exception 'queue_name cannot be blank.';
  end if;
  if p_max_retries < 0 or p_max_retries > 10 then
    raise exception 'max_retries must be between 0 and 10. Default is 3 with backoff 1m/5m/15m.';
  end if;

  select * into v_row from write_queue_items where idempotency_key = p_idempotency_key;
  if found then
    return jsonb_build_object(
      'enqueued', false,
      'existing', true,
      'item', _write_queue_summary(v_row),
      'notice', 'A queued write with this idempotency_key already exists; returning it without creating a duplicate.'
    );
  end if;

  insert into write_queue_items (
    queue_name, idempotency_key, payload, available_at, max_retries, created_by
  ) values (
    p_queue_name, p_idempotency_key, p_payload, coalesce(p_available_at, now()), p_max_retries, v_agent
  )
  returning * into v_row;

  perform _emit(v_agent, 'write_queue.enqueued', 'write_queue', v_row.id::text,
    jsonb_build_object('queue_name', v_row.queue_name, 'idempotency_key', v_row.idempotency_key),
    'standard',
    'write_queue.enqueued:' || v_row.idempotency_key);

  return jsonb_build_object('enqueued', true, 'existing', false, 'item', _write_queue_summary(v_row));
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
  v_expired int;
begin
  v_agent := _auth_agent(p_agent_key);
  if coalesce(p_queue_name, '') = '' then
    raise exception 'queue_name cannot be blank.';
  end if;
  if p_lease_seconds < 0 then
    raise exception 'lease_seconds must be zero or greater.';
  end if;

  v_expired := _write_queue_expire_leases();

  with next_item as (
    select id
    from write_queue_items
    where queue_name = p_queue_name
      and status = 'queued'
      and available_at <= now()
    order by available_at, created_at
    for update skip locked
    limit 1
  )
  update write_queue_items q
  set status = 'leased',
      leased_by = v_agent,
      lease_expires_at = now() + make_interval(secs => greatest(p_lease_seconds, 0)),
      updated_at = now()
  from next_item
  where q.id = next_item.id
  returning q.* into v_row;

  if v_row.id is null then
    return jsonb_build_object('leased', false, 'queue_name', p_queue_name, 'expired_leases', v_expired);
  end if;

  perform _emit(v_agent, 'write_queue.leased', 'write_queue', v_row.id::text,
    jsonb_build_object('queue_name', v_row.queue_name, 'lease_expires_at', v_row.lease_expires_at,
      'retry_count', v_row.retry_count, 'expired_leases', v_expired),
    'standard');

  return jsonb_build_object('leased', true, 'expired_leases', v_expired, 'item', _write_queue_summary(v_row));
end $$;

create or replace function write_queue_ack(
  p_agent_key text,
  p_item_id uuid,
  p_result jsonb default '{}'
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_agent text;
  v_row write_queue_items;
begin
  v_agent := _auth_agent(p_agent_key);
  select * into v_row from write_queue_items where id = p_item_id for update;
  if not found then
    raise exception 'No queued write with id %. Use write_queue_status to inspect queue state.', p_item_id;
  end if;
  if v_row.status = 'acked' then
    return jsonb_build_object('acked', false, 'existing', true, 'item', _write_queue_summary(v_row),
      'notice', 'Queued write is already acked. No action taken.');
  end if;
  if v_row.status = 'dead_letter' then
    raise exception 'Queued write % is already dead-lettered. Do not ack it; inspect write_queue_exceptions.', p_item_id;
  end if;
  if v_row.status <> 'leased' or v_row.leased_by is distinct from v_agent then
    raise exception 'Queued write % is not leased by you (status %, owner %). Lease it with write_queue_lease before acking.',
      p_item_id, v_row.status, coalesce(v_row.leased_by, 'nobody');
  end if;

  update write_queue_items
  set status = 'acked',
      ack_result = coalesce(p_result, '{}'),
      acked_at = now(),
      lease_expires_at = null,
      updated_at = now()
  where id = p_item_id
  returning * into v_row;

  perform _emit(v_agent, 'write_queue.acked', 'write_queue', p_item_id::text,
    jsonb_build_object('queue_name', v_row.queue_name, 'idempotency_key', v_row.idempotency_key,
      'result', coalesce(p_result, '{}')),
    'standard');

  return jsonb_build_object('acked', true, 'item', _write_queue_summary(v_row));
end $$;

create or replace function write_queue_retry(
  p_agent_key text,
  p_item_id uuid,
  p_error text
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_agent text;
  v_row write_queue_items;
  v_backoff int;
begin
  v_agent := _auth_agent(p_agent_key);
  select * into v_row from write_queue_items where id = p_item_id for update;
  if not found then
    raise exception 'No queued write with id %. Use write_queue_status to inspect queue state.', p_item_id;
  end if;
  if v_row.status = 'acked' then
    raise exception 'Queued write % is already acked. Do not retry it.', p_item_id;
  end if;
  if v_row.status = 'dead_letter' then
    return jsonb_build_object('retry_scheduled', false, 'dead_lettered', true, 'item', _write_queue_summary(v_row),
      'notice', 'Queued write is already dead-lettered. No action taken.');
  end if;
  if v_row.status <> 'leased' or v_row.leased_by is distinct from v_agent then
    raise exception 'Queued write % is not leased by you (status %, owner %). Lease it with write_queue_lease before retrying.',
      p_item_id, v_row.status, coalesce(v_row.leased_by, 'nobody');
  end if;

  if v_row.retry_count >= v_row.max_retries then
    update write_queue_items
    set status = 'dead_letter',
        last_error = p_error,
        lease_expires_at = null,
        dead_lettered_at = now(),
        updated_at = now()
    where id = p_item_id
    returning * into v_row;

    insert into write_queue_exceptions (
      write_queue_id, queue_name, idempotency_key, payload, retry_count, max_retries,
      last_error, created_by, dead_lettered_by
    ) values (
      v_row.id, v_row.queue_name, v_row.idempotency_key, v_row.payload, v_row.retry_count,
      v_row.max_retries, p_error, v_row.created_by, v_agent
    )
    on conflict (write_queue_id) do update
      set last_error = excluded.last_error,
          dead_lettered_by = excluded.dead_lettered_by;

    perform _emit(v_agent, 'write_queue.dead_lettered', 'write_queue', p_item_id::text,
      jsonb_build_object('queue_name', v_row.queue_name, 'idempotency_key', v_row.idempotency_key,
        'retry_count', v_row.retry_count, 'max_retries', v_row.max_retries, 'error', p_error),
      'major');

    return jsonb_build_object('retry_scheduled', false, 'dead_lettered', true, 'item', _write_queue_summary(v_row));
  end if;

  v_backoff := _write_queue_backoff_seconds(v_row.retry_count + 1);
  update write_queue_items
  set status = 'queued',
      retry_count = retry_count + 1,
      available_at = now() + make_interval(secs => v_backoff),
      leased_by = null,
      lease_expires_at = null,
      last_error = p_error,
      updated_at = now()
  where id = p_item_id
  returning * into v_row;

  perform _emit(v_agent, 'write_queue.retry_scheduled', 'write_queue', p_item_id::text,
    jsonb_build_object('queue_name', v_row.queue_name, 'idempotency_key', v_row.idempotency_key,
      'retry_count', v_row.retry_count, 'backoff_seconds', v_backoff, 'available_at', v_row.available_at,
      'error', p_error),
    'standard');

  return jsonb_build_object('retry_scheduled', true, 'dead_lettered', false,
    'backoff_seconds', v_backoff, 'item', _write_queue_summary(v_row));
end $$;

create or replace function write_queue_status(
  p_agent_key text,
  p_item_id uuid default null,
  p_idempotency_key text default null,
  p_queue_name text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_row write_queue_items;
begin
  perform _auth_agent(p_agent_key);
  perform _write_queue_expire_leases();

  if p_item_id is not null or p_idempotency_key is not null then
    select * into v_row
    from write_queue_items
    where (p_item_id is null or id = p_item_id)
      and (p_idempotency_key is null or idempotency_key = p_idempotency_key)
    order by created_at desc
    limit 1;
    if not found then
      return jsonb_build_object('found', false);
    end if;
    return jsonb_build_object(
      'found', true,
      'item', _write_queue_summary(v_row),
      'exceptions', coalesce((
        select jsonb_agg(to_jsonb(e) order by e.created_at)
        from write_queue_exceptions e
        where e.write_queue_id = v_row.id
      ), '[]')
    );
  end if;

  return jsonb_build_object(
    'queue_name', p_queue_name,
    'counts', coalesce((
      select jsonb_object_agg(status, count)
      from (
        select status, count(*)::int
        from write_queue_items
        where p_queue_name is null or queue_name = p_queue_name
        group by status
      ) c
    ), '{}'),
    'next_ready', (
      select min(available_at)
      from write_queue_items
      where status = 'queued'
        and (p_queue_name is null or queue_name = p_queue_name)
    ),
    'recent_exceptions', coalesce((
      select jsonb_agg(to_jsonb(e) order by e.created_at desc)
      from (
        select *
        from write_queue_exceptions e
        where p_queue_name is null or e.queue_name = p_queue_name
        order by e.created_at desc
        limit 10
      ) e
    ), '[]')
  );
end $$;

revoke execute on function
  _write_queue_backoff_seconds(int),
  _write_queue_summary(write_queue_items),
  _write_queue_expire_leases()
from public, anon, authenticated;

grant execute on function
  write_queue_enqueue(text, text, jsonb, text, timestamptz, int),
  write_queue_lease(text, text, int),
  write_queue_ack(text, uuid, jsonb),
  write_queue_retry(text, uuid, text),
  write_queue_status(text, uuid, text, text)
to anon, authenticated;
