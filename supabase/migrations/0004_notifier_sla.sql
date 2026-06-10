-- Backbone 0004 — notifier wiring (events -> edge function -> Slack) and SLA cron.
-- Slack carries pointers, never truth: the notifier posts one-liners with deep links.

create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron;

-- Fire-and-forget HTTP post to the notifier edge function for notify-worthy verbs.
-- Config (notifier_url, notifier_bearer) lives in app_config; if absent, no-op —
-- the ledger never depends on Slack being up (degraded mode requirement).
create or replace function _notify_event() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
declare v_url text; v_bearer text;
begin
  if new.verb not in (
    'task.created','task.completed','task.superseded',
    'decision.opened','decision.resolved','decision.escalated',
    'request.opened','request.fulfilled'
  ) then
    return new;
  end if;
  select value into v_url from app_config where key = 'notifier_url';
  select value into v_bearer from app_config where key = 'notifier_bearer';
  if v_url is null then
    return new;
  end if;
  perform net.http_post(
    url := v_url,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || coalesce(v_bearer, '')
    ),
    body := to_jsonb(new)
  );
  return new;
end $$;

create trigger events_notify
after insert on events
for each row execute function _notify_event();

-- SLA enforcement + lease expiry, every 15 minutes. Escalations insert
-- decision.escalated events, which the trigger above pushes to Slack.
select cron.schedule('backbone-sla-check', '*/15 * * * *', 'select public.sla_check()');
