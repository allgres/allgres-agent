-- Claim is the authorization boundary. An already claimed external request
-- cannot be recalled; queued requests are checked against live state here.
CREATE TABLE allgres_private.execution_rules (
  agent_id uuid NOT NULL REFERENCES allgres_private.agents(agent_id) ON DELETE CASCADE,
  action text NOT NULL CHECK (action IN ('call_function', 'execute_sql', 'run_procedure')),
  resource text NOT NULL DEFAULT '*',
  decision text NOT NULL CHECK (decision IN ('allow', 'approve', 'deny')),
  generation bigint NOT NULL DEFAULT 1,
  PRIMARY KEY (agent_id, action, resource)
);

CREATE OR REPLACE FUNCTION allgres_public.fn_set_execution_rule(
  p_agent_id uuid, p_action text, p_resource text, p_decision text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = allgres_private, pg_temp AS $fn$
BEGIN
  IF p_resource IS NULL OR btrim(p_resource) = '' THEN
    RAISE EXCEPTION 'resource must be a name or *';
  END IF;
  INSERT INTO allgres_private.execution_rules(agent_id, action, resource, decision)
  VALUES (p_agent_id, p_action, p_resource, p_decision)
  ON CONFLICT (agent_id, action, resource) DO UPDATE
    SET decision = EXCLUDED.decision, generation = execution_rules.generation + 1;
  PERFORM allgres_private.audit('execution_rules.set', jsonb_build_object(
    'agent_id', p_agent_id, 'action', p_action, 'resource', p_resource, 'decision', p_decision));
  RETURN jsonb_build_object('ok', true);
END;
$fn$;

-- No new status enum is needed: ambiguous attempts stay lost and their task
-- waits for an operator. Used by both transport completion and watchdog loss.
CREATE OR REPLACE FUNCTION allgres_private.pause_ambiguous_outbound(p_call_id uuid, p_reason text)
RETURNS void LANGUAGE plpgsql SET search_path = allgres_private, pg_temp AS $fn$
DECLARE c allgres_private.outbound_calls%ROWTYPE;
BEGIN
  SELECT * INTO STRICT c FROM allgres_private.outbound_calls WHERE call_id = p_call_id FOR UPDATE;
  UPDATE allgres_private.outbound_calls SET status = 'lost', error = p_reason, updated_at = now()
  WHERE call_id = p_call_id;
  UPDATE allgres_private.tasks SET status = 'waiting_human', updated_at = now()
  WHERE task_id = c.task_id AND status = 'running';
  IF FOUND THEN
    INSERT INTO allgres_private.human_approvals(task_id, status, payload, expires_at)
    VALUES (c.task_id, 'pending', jsonb_build_object(
      'reason', format(
        'The %s call to %s may already have executed. Check the destination before allowing a retry.',
        COALESCE(c.method, 'HTTP'), COALESCE(c.url, c.function)
      ),
      'ambiguous_outbound_call_id', c.call_id, 'method', c.method, 'url', c.url,
      'error', p_reason), clock_timestamp() + interval '24 hours');
    PERFORM allgres_private.append_log(c.task_id, (SELECT step_count FROM allgres_private.tasks WHERE task_id = c.task_id), 'error', jsonb_build_object(
      'reason', 'outbound_result_unknown', 'call_id', c.call_id, 'detail', p_reason));
  END IF;
END;
$fn$;

-- Only an explicit retry reuses an operation's key. Identical new operations
-- must remain distinct. A retry may not change the request or cross tasks.
CREATE OR REPLACE FUNCTION allgres_private.outbound_operation_key(
  p_task uuid, p_retry text, p_method text, p_url text, p_body jsonb,
  p_headers jsonb, p_connection uuid, p_custom text
) RETURNS text LANGUAGE plpgsql SET search_path = allgres_private, pg_temp AS $fn$
DECLARE c allgres_private.outbound_calls%ROWTYPE;
BEGIN
  IF p_retry IS NULL THEN RETURN COALESCE(p_custom, gen_random_uuid()::text); END IF;
  SELECT * INTO c FROM allgres_private.outbound_calls WHERE call_id = p_retry::uuid;
  IF NOT FOUND OR c.task_id <> p_task OR c.status NOT IN ('lost', 'harvested')
     OR c.method IS DISTINCT FROM p_method OR c.url IS DISTINCT FROM p_url
     OR c.request_body IS DISTINCT FROM p_body
     OR (c.request_headers - 'idempotency-key') IS DISTINCT FROM (p_headers - 'idempotency-key')
     OR c.connection_id IS DISTINCT FROM p_connection OR c.idempotency_key IS NULL
     OR (p_custom IS NOT NULL AND p_custom <> c.idempotency_key) THEN
    RAISE EXCEPTION 'retry_of_call_id must identify the same completed/lost request in this task';
  END IF;
  RETURN c.idempotency_key;
END;
$fn$;

CREATE OR REPLACE FUNCTION allgres_private.guard_queued_call(p_queue text, p_call_id uuid)
RETURNS boolean LANGUAGE plpgsql SET search_path = allgres_private, pg_temp AS $fn$
DECLARE
  q jsonb;
  t allgres_private.tasks%ROWTYPE;
  a allgres_private.agents%ROWTYPE;
  f allgres_private.functions%ROWTYPE;
  pr allgres_private.procedures%ROWTYPE;
  conn allgres_private.api_connections%ROWTYPE;
  provider allgres_private.llm_providers%ROWTYPE;
  v_action text;
  v_resource text;
  v_reason text;
  v_generation int;
  v_rules jsonb;
  v_snapshot jsonb;
  v_requires boolean;
  v_approval allgres_private.human_approvals%ROWTYPE;
BEGIN
  IF p_queue NOT IN ('outbound_calls', 'sql_calls', 'function_calls', 'procedure_calls') THEN
    RAISE EXCEPTION 'unsupported execution queue';
  END IF;
  EXECUTE format('SELECT to_jsonb(c) FROM allgres_private.%I c WHERE call_id = $1 FOR UPDATE', p_queue)
    INTO q USING p_call_id;
  IF q IS NULL OR q->>'status' <> 'queued' THEN RETURN false; END IF;
  SELECT * INTO t FROM allgres_private.tasks WHERE task_id = (q->>'task_id')::uuid FOR UPDATE;
  IF t.status <> 'running' THEN RETURN false; END IF;
  SELECT * INTO a FROM allgres_private.agents WHERE agent_id = t.agent_id;
  SELECT generation INTO v_generation FROM allgres_private.policies WHERE agent_id = t.agent_id;
  IF NOT COALESCE(a.is_active, false) THEN v_reason := 'agent_inactive'; END IF;

  IF p_queue = 'sql_calls' THEN
    v_action := 'execute_sql'; v_resource := '*';
    BEGIN
      PERFORM allgres_private.fn_validate_sql(t.agent_id, q->>'sql');
    EXCEPTION WHEN others THEN v_reason := 'sql_permission_revoked: ' || SQLERRM;
    END;
  ELSIF p_queue = 'procedure_calls' THEN
    v_action := 'run_procedure';
    SELECT * INTO pr FROM allgres_private.procedures WHERE procedure_id = (q->>'procedure_id')::uuid;
    v_resource := pr.name;
    IF NOT COALESCE(pr.is_active AND pr.build_status = 'built'
      AND allgres_private.agent_has_permission(t.agent_id, 'procedure', pr.name), false) THEN
      v_reason := 'procedure_not_permitted';
    END IF;
  ELSIF p_queue = 'function_calls' OR q->>'kind' IN ('function', 'mcp') THEN
    v_action := 'call_function';
    SELECT * INTO f FROM allgres_private.functions
    WHERE function_id = COALESCE((q->>'function_id')::uuid, (q->>'procedure_function_id')::uuid);
    v_resource := COALESCE(f.name, q->>'function');
    IF NOT allgres_private.agent_has_permission(t.agent_id, 'function', v_resource) THEN
      SELECT p.* INTO pr FROM allgres_private.procedures p
      JOIN allgres_private.procedure_function_bindings b USING (procedure_id)
      WHERE b.function_id = f.function_id AND p.is_active
        AND allgres_private.agent_has_permission(t.agent_id, 'procedure', p.name)
        AND (q->>'procedure_id' IS NULL OR p.procedure_id = (q->>'procedure_id')::uuid)
      ORDER BY p.procedure_id LIMIT 1;
      IF NOT FOUND THEN v_reason := 'function_not_permitted'; END IF;
    END IF;
    IF f.function_id IS NOT NULL AND (NOT f.is_active OR
        (p_queue = 'function_calls' AND f.build_status <> 'built')) THEN
      v_reason := 'function_unavailable';
    END IF;
    IF p_queue = 'outbound_calls' AND pr.procedure_id IS NULL
       AND NOT allgres_private.agent_has_permission(t.agent_id, 'http_host', allgres_private.url_host(q->>'url')) THEN
      v_reason := 'http_host_not_permitted';
    END IF;
  END IF;

  IF p_queue = 'outbound_calls' THEN
    IF q->>'connection_id' IS NOT NULL THEN
      SELECT * INTO conn FROM allgres_private.api_connections WHERE connection_id = (q->>'connection_id')::uuid;
      IF NOT COALESCE(conn.is_enabled, false)
         OR NOT (q->>'url' = conn.base_url OR starts_with(q->>'url', rtrim(conn.base_url, '/') || '/'))
         OR (q->>'auth_kind') IS DISTINCT FROM NULLIF(conn.auth_kind, 'none')
         OR ((q->>'allow_private')::boolean AND NOT conn.allow_private_network) THEN
        v_reason := 'connection_changed_or_disabled';
      END IF;
    END IF;
    IF q->>'provider_id' IS NOT NULL THEN
      SELECT * INTO provider FROM allgres_private.llm_providers WHERE provider_id = (q->>'provider_id')::uuid;
      IF NOT COALESCE(provider.is_enabled, false)
         OR NOT starts_with(q->>'url', rtrim(provider.base_url, '/') || '/')
         OR ((q->>'allow_private')::boolean AND NOT provider.allow_private_network) THEN
        v_reason := 'provider_changed_or_disabled';
      END IF;
    END IF;
  END IF;

  SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.resource), '[]'::jsonb),
         COALESCE(bool_or(r.decision = 'approve'), false)
    INTO v_rules, v_requires FROM allgres_private.execution_rules r
    WHERE r.agent_id = t.agent_id AND r.action = v_action AND r.resource IN ('*', v_resource);
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_rules) r WHERE r->>'decision' = 'deny') THEN
    v_reason := 'execution_denied';
  END IF;
  IF v_reason IS NOT NULL THEN
    EXECUTE format('UPDATE allgres_private.%I SET status = ''lost'', updated_at = now() WHERE call_id = $1', p_queue)
      USING p_call_id;
    UPDATE allgres_private.tasks SET status = 'failed', error = v_reason, updated_at = now() WHERE task_id = t.task_id;
    PERFORM allgres_private.append_log(t.task_id, t.step_count, 'error', jsonb_build_object(
      'reason', v_reason, 'queue', p_queue, 'call_id', p_call_id));
    PERFORM allgres_private.maybe_complete_session(t.session_id);
    RETURN false;
  END IF;

  -- Includes executable definition generations, live policy and rules. Secrets
  -- are never part of this snapshot; injection still happens after this gate.
  v_snapshot := jsonb_build_object(
    'request', q - ARRAY['status','created_at','updated_at','response_status','response_body','error','result'],
    'policy_generation', v_generation, 'rules', v_rules,
    'function_generation', f.generation, 'procedure_generation', pr.generation,
    'connection', to_jsonb(conn), 'provider', to_jsonb(provider));
  SELECT * INTO v_approval FROM allgres_private.human_approvals
    WHERE task_id = t.task_id AND payload->>'queue' = p_queue AND payload->>'call_id' = p_call_id::text
    ORDER BY created_at DESC, approval_id DESC LIMIT 1 FOR UPDATE;
  -- A previously required approval cannot be bypassed by relaxing its rule.
  IF v_requires OR v_approval.approval_id IS NOT NULL THEN
    IF v_approval.status = 'approved' AND v_approval.expires_at > clock_timestamp()
       AND v_approval.payload->'snapshot' = v_snapshot THEN
      RETURN true;
    END IF;
    IF v_approval.approval_id IS NOT NULL THEN
      UPDATE allgres_private.human_approvals SET status = 'rejected', decided_at = now(),
        reply_text = 'Execution approval expired or request/policy changed.'
      WHERE approval_id = v_approval.approval_id;
    END IF;
    INSERT INTO allgres_private.human_approvals(task_id, status, payload, expires_at)
    VALUES (t.task_id, 'pending', jsonb_build_object(
      'reason', 'Execution requires approval', 'queue', p_queue, 'call_id', p_call_id,
      'action', v_action, 'resource', v_resource, 'snapshot', v_snapshot),
      clock_timestamp() + interval '24 hours');
    UPDATE allgres_private.tasks SET status = 'waiting_human', updated_at = now() WHERE task_id = t.task_id;
    RETURN false;
  END IF;
  RETURN true;
END;
$fn$;
