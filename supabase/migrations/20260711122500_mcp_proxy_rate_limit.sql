-- BLD-601: durable per-token rate limits for the hosted Backbone MCP proxy.

create table if not exists mcp_proxy_rate_limit_buckets (
  bucket_key         text primary key,
  capacity           numeric not null check (capacity > 0),
  refill_per_second  numeric not null check (refill_per_second > 0),
  tokens             numeric not null check (tokens >= 0),
  last_refill_at     timestamptz not null default now(),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

alter table mcp_proxy_rate_limit_buckets enable row level security;
revoke all on mcp_proxy_rate_limit_buckets from anon, authenticated;

create or replace function mcp_proxy_rate_limit_acquire(
  p_agent_key text,
  p_bucket_key text,
  p_capacity numeric,
  p_refill_per_second numeric,
  p_request_count int default 1,
  p_now timestamptz default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_now timestamptz := coalesce(p_now, now());
  v_row mcp_proxy_rate_limit_buckets;
  v_tokens numeric;
  v_retry_seconds int;
begin
  perform _auth_agent(p_agent_key);
  if coalesce(p_bucket_key, '') = '' then
    raise exception 'bucket_key cannot be blank.';
  end if;
  if p_capacity is null or p_capacity <= 0 or p_capacity > 10000 then
    raise exception 'capacity must be between 0 and 10000.';
  end if;
  if p_refill_per_second is null or p_refill_per_second <= 0 or p_refill_per_second > 10000 then
    raise exception 'refill_per_second must be between 0 and 10000.';
  end if;
  if p_request_count is null or p_request_count < 1 or p_request_count > 10000 then
    raise exception 'request_count must be between 1 and 10000.';
  end if;

  insert into mcp_proxy_rate_limit_buckets (
    bucket_key, capacity, refill_per_second, tokens, last_refill_at
  ) values (
    p_bucket_key, p_capacity, p_refill_per_second, p_capacity, v_now
  )
  on conflict (bucket_key) do nothing;

  select * into v_row
  from mcp_proxy_rate_limit_buckets
  where bucket_key = p_bucket_key
  for update;

  v_tokens := least(
    p_capacity,
    least(v_row.tokens, p_capacity)
      + greatest(0, extract(epoch from v_now - v_row.last_refill_at)) * p_refill_per_second
  );

  if v_tokens >= p_request_count then
    update mcp_proxy_rate_limit_buckets
    set capacity = p_capacity,
        refill_per_second = p_refill_per_second,
        tokens = v_tokens - p_request_count,
        last_refill_at = v_now,
        updated_at = now()
    where bucket_key = p_bucket_key;

    return jsonb_build_object(
      'granted', true,
      'capacity', p_capacity,
      'tokens_remaining', round(v_tokens - p_request_count, 3)
    );
  end if;

  v_retry_seconds := greatest(1, ceiling((p_request_count - v_tokens) / p_refill_per_second)::int);

  update mcp_proxy_rate_limit_buckets
  set capacity = p_capacity,
      refill_per_second = p_refill_per_second,
      tokens = v_tokens,
      last_refill_at = v_now,
      updated_at = now()
  where bucket_key = p_bucket_key;

  return jsonb_build_object(
    'granted', false,
    'capacity', p_capacity,
    'tokens_available', round(v_tokens, 3),
    'retry_after_seconds', v_retry_seconds
  );
end $$;

grant execute on function
  mcp_proxy_rate_limit_acquire(text, text, numeric, numeric, int, timestamptz)
to anon, authenticated;
