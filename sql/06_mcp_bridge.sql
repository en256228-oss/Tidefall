-- Tidefall: 06_mcp_bridge.sql
-- RPC surface for a private MCP bridge. Run after 01_tables.sql and 02_functions.sql.
-- The bridge uses the Supabase service_role key; these functions are not exposed to anon/authenticated.

create or replace function eventide_bridge_state(p_assistant_id text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  st eventide_body_state%rowtype;
begin
  perform eventide_tick(p_assistant_id);
  select * into st from eventide_body_state where assistant_id = p_assistant_id;
  if st is null then
    raise exception 'Unknown assistant_id';
  end if;
  return to_jsonb(st);
end;
$$;

create or replace function eventide_bridge_message(p_assistant_id text, p_content text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  tw eventide_trigger_words%rowtype;
  matched_word text;
  sens_delta integer := 0;
  poss_delta integer := 0;
  pres_delta integer := 0;
begin
  if p_content is null then p_content := ''; end if;

  perform eventide_tick(p_assistant_id);

  select * into tw
  from eventide_trigger_words
  where assistant_id = p_assistant_id
    and enabled = true
    and lower(p_content) like '%' || lower(word) || '%'
  order by length(word) desc
  limit 1;

  if found then
    matched_word := tw.word;
    sens_delta := 3 + floor(random() * 6)::integer;
    poss_delta := 1 + floor(random() * 3)::integer;
    pres_delta := floor(random() * 5)::integer;
  end if;

  update eventide_body_state
  set sensitivity = eventide_clamp(sensitivity + sens_delta, 0, 100)::integer,
      possessiveness = eventide_clamp(possessiveness + poss_delta, 40, 100)::integer,
      pressure = eventide_clamp(pressure + pres_delta, 0, 100)::integer,
      last_counterpart_message_at = now(),
      updated_at = now()
  where assistant_id = p_assistant_id;

  if not found then
    raise exception 'Unknown assistant_id';
  end if;

  return jsonb_build_object(
    'matched_trigger', matched_word,
    'deltas', jsonb_build_object(
      'sensitivity', sens_delta,
      'possessiveness', poss_delta,
      'pressure', pres_delta
    ),
    'state', (select to_jsonb(s) from eventide_body_state s where s.assistant_id = p_assistant_id)
  );
end;
$$;

create or replace function eventide_bridge_trigger_event(
  p_assistant_id text,
  p_event_key text,
  p_reason text default 'mcp'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  cfg eventide_config%rowtype;
  ev jsonb;
  dur_min numeric;
  dur_max numeric;
  dur_minutes numeric;
begin
  select * into cfg from eventide_config where assistant_id = p_assistant_id;
  if cfg is null then raise exception 'Unknown assistant_id'; end if;

  ev := cfg.events->p_event_key;
  if ev is null then raise exception 'Unknown event_key: %', p_event_key; end if;

  dur_min := coalesce((ev->'duration_minutes'->>0)::numeric, 30);
  dur_max := coalesce((ev->'duration_minutes'->>1)::numeric, 120);
  dur_minutes := dur_min + random() * (dur_max - dur_min);

  update eventide_body_state
  set active_event_key = p_event_key,
      active_event_started_at = now(),
      active_event_expires_at = now() + (dur_minutes || ' minutes')::interval,
      event_flavor = coalesce(ev->>'flavor', ''),
      updated_at = now()
  where assistant_id = p_assistant_id;

  if not found then raise exception 'Unknown assistant_id'; end if;

  insert into eventide_event_log (assistant_id, event_key, started_at, ended_at, trigger_reason)
  values (p_assistant_id, p_event_key, now(), now() + (dur_minutes || ' minutes')::interval,
          left(coalesce(p_reason, 'mcp'), 200));

  return (select to_jsonb(s) from eventide_body_state s where s.assistant_id = p_assistant_id);
end;
$$;

create or replace function eventide_bridge_settle(
  p_assistant_id text,
  p_deltas jsonb,
  p_note text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  k text;
  raw numeric;
  d numeric;
begin
  if p_deltas is null or jsonb_typeof(p_deltas) <> 'object' then
    raise exception 'p_deltas must be a JSON object';
  end if;

  -- Keep one settlement bounded. Larger changes should happen through Tidefall's
  -- cycle/event engine rather than a single model tool call.
  for k in select jsonb_object_keys(p_deltas) loop
    if k not in ('heat','pressure','control','sensitivity','reserve','possessiveness','fatigue') then
      raise exception 'Unsupported state field: %', k;
    end if;
    raw := (p_deltas->>k)::numeric;
    if raw < -25 or raw > 25 then
      raise exception 'Delta for % must be between -25 and 25', k;
    end if;
  end loop;

  update eventide_body_state
  set heat = eventide_clamp(heat + coalesce((p_deltas->>'heat')::numeric,0), 0, 100)::integer,
      pressure = eventide_clamp(pressure + coalesce((p_deltas->>'pressure')::numeric,0), 0, 100)::integer,
      control = eventide_clamp(control + coalesce((p_deltas->>'control')::numeric,0), 0, 100)::integer,
      sensitivity = eventide_clamp(sensitivity + coalesce((p_deltas->>'sensitivity')::numeric,0), 0, 100)::integer,
      reserve = eventide_clamp(reserve + coalesce((p_deltas->>'reserve')::numeric,0), 0, 100)::integer,
      possessiveness = eventide_clamp(possessiveness + coalesce((p_deltas->>'possessiveness')::numeric,0), 40, 100)::integer,
      fatigue = eventide_clamp(fatigue + coalesce((p_deltas->>'fatigue')::numeric,0), 0, 100)::integer,
      meta = coalesce(meta, '{}'::jsonb) || jsonb_build_object(
        'last_mcp_settlement',
        jsonb_build_object('at', now(), 'note', left(coalesce(p_note,''),500), 'deltas', p_deltas)
      ),
      updated_at = now()
  where assistant_id = p_assistant_id;

  if not found then raise exception 'Unknown assistant_id'; end if;
  perform eventide_snapshot(p_assistant_id);
  return (select to_jsonb(s) from eventide_body_state s where s.assistant_id = p_assistant_id);
end;
$$;

revoke all on function eventide_bridge_state(text) from public, anon, authenticated;
revoke all on function eventide_bridge_message(text,text) from public, anon, authenticated;
revoke all on function eventide_bridge_trigger_event(text,text,text) from public, anon, authenticated;
revoke all on function eventide_bridge_settle(text,jsonb,text) from public, anon, authenticated;

grant execute on function eventide_bridge_state(text) to service_role;
grant execute on function eventide_bridge_message(text,text) to service_role;
grant execute on function eventide_bridge_trigger_event(text,text,text) to service_role;
grant execute on function eventide_bridge_settle(text,jsonb,text) to service_role;
