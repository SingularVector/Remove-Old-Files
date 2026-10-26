-- Prototype central-store contract. Database-backed runs are report-only.
-- Apply to a new database as its owner; runtime role provisioning is a later step.
BEGIN;

CREATE SCHEMA retention;
REVOKE ALL ON SCHEMA retention FROM PUBLIC;

CREATE TABLE retention.schema_version (
    version integer PRIMARY KEY CHECK (version = 1),
    installed_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
INSERT INTO retention.schema_version (version) VALUES (1);

CREATE TABLE retention.workers (
    worker_id uuid PRIMARY KEY,
    name text NOT NULL UNIQUE CHECK (btrim(name) <> ''),
    enabled boolean NOT NULL DEFAULT true
);

CREATE TABLE retention.scopes (
    scope_id uuid PRIMARY KEY,
    name text NOT NULL UNIQUE CHECK (btrim(name) <> ''),
    enabled boolean NOT NULL DEFAULT true
);

CREATE TABLE retention.policies (
    policy_id uuid PRIMARY KEY,
    worker_id uuid NOT NULL REFERENCES retention.workers,
    scope_id uuid NOT NULL REFERENCES retention.scopes,
    current_revision integer NOT NULL DEFAULT 0 CHECK (current_revision >= 0)
);

CREATE TABLE retention.policy_revisions (
    policy_id uuid NOT NULL REFERENCES retention.policies,
    revision integer NOT NULL CHECK (revision > 0),
    owner_name text NOT NULL CHECK (btrim(owner_name) <> ''),
    document jsonb NOT NULL CHECK (jsonb_typeof(document) = 'object'),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (policy_id, revision)
);

ALTER TABLE retention.policies ADD CONSTRAINT policies_current_revision_fk
    FOREIGN KEY (policy_id, current_revision)
    REFERENCES retention.policy_revisions (policy_id, revision)
    DEFERRABLE INITIALLY DEFERRED;

CREATE FUNCTION retention.reject_revision_change()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'Policy revisions are immutable; publish a new revision instead';
END;
$$;

CREATE TRIGGER immutable_policy_revision
    BEFORE UPDATE OR DELETE ON retention.policy_revisions
    FOR EACH ROW EXECUTE FUNCTION retention.reject_revision_change();

CREATE TABLE retention.runs (
    run_id uuid PRIMARY KEY,
    policy_id uuid NOT NULL,
    revision integer NOT NULL,
    worker_id uuid NOT NULL REFERENCES retention.workers,
    scope_id uuid NOT NULL REFERENCES retention.scopes,
    mode text NOT NULL DEFAULT 'ReportOnly' CHECK (mode = 'ReportOnly'),
    state text NOT NULL CHECK (state IN ('Running', 'Completed', 'Partial', 'Failed', 'Disabled', 'NeedsReview', 'Resolved')),
    lease_token uuid NOT NULL UNIQUE,
    lease_expires_at timestamptz NOT NULL,
    started_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    finished_at timestamptz,
    result jsonb,
    resolution jsonb,
    FOREIGN KEY (policy_id, revision) REFERENCES retention.policy_revisions,
    CHECK ((state IN ('Running', 'NeedsReview') AND finished_at IS NULL)
        OR (state NOT IN ('Running', 'NeedsReview') AND finished_at IS NOT NULL))
);

-- An expired worker must not be silently replaced while it may still be running.
CREATE UNIQUE INDEX one_active_run_per_scope ON retention.runs (scope_id)
    WHERE state IN ('Running', 'NeedsReview');

CREATE TABLE retention.run_events (
    event_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id uuid NOT NULL REFERENCES retention.runs,
    occurred_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    kind text NOT NULL,
    detail jsonb NOT NULL DEFAULT '{}'::jsonb
);

CREATE FUNCTION retention.reject_event_change()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'Run events are append-only';
END;
$$;

CREATE TRIGGER immutable_run_event
    BEFORE UPDATE OR DELETE ON retention.run_events
    FOR EACH ROW EXECUTE FUNCTION retention.reject_event_change();

CREATE FUNCTION retention.publish_policy(
    p_policy_id uuid,
    p_expected_revision integer,
    p_worker_id uuid,
    p_scope_id uuid,
    p_owner_name text,
    p_document jsonb
)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
    existing retention.policies%ROWTYPE;
    next_revision integer;
BEGIN
    IF p_expected_revision IS NULL OR p_expected_revision < 0 OR
        p_owner_name IS NULL OR btrim(p_owner_name) = '' OR
        p_document IS NULL OR jsonb_typeof(p_document) <> 'object' THEN
        RAISE EXCEPTION 'Expected revision, owner and policy document are required';
    END IF;
    IF NOT (p_document ?& ARRAY['root_path', 'file_pattern', 'retention_days', 'recurse', 'enabled']) OR
        jsonb_typeof(p_document->'root_path') <> 'string' OR btrim(p_document->>'root_path') = '' OR
        jsonb_typeof(p_document->'file_pattern') <> 'string' OR btrim(p_document->>'file_pattern') = '' OR
        jsonb_typeof(p_document->'retention_days') <> 'number' OR
        (p_document->>'retention_days') !~ '^[0-9]{1,5}$' OR
        jsonb_typeof(p_document->'recurse') <> 'boolean' OR
        jsonb_typeof(p_document->'enabled') <> 'boolean' THEN
        RAISE EXCEPTION 'Policy fields have missing or invalid types';
    END IF;
    IF (p_document->>'retention_days')::integer NOT BETWEEN 1 AND 36500 THEN
        RAISE EXCEPTION 'Retention must be between 1 and 36500 days';
    END IF;

    -- Publishing and claiming use scope -> worker -> policy lock order.
    PERFORM 1 FROM retention.scopes WHERE scope_id = p_scope_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Scope does not exist';
    END IF;
    PERFORM 1 FROM retention.workers WHERE worker_id = p_worker_id FOR SHARE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Worker does not exist';
    END IF;
    IF p_expected_revision = 0 THEN
        INSERT INTO retention.policies (policy_id, worker_id, scope_id)
        VALUES (p_policy_id, p_worker_id, p_scope_id)
        ON CONFLICT (policy_id) DO NOTHING;
    END IF;
    SELECT * INTO existing FROM retention.policies WHERE policy_id = p_policy_id FOR UPDATE;
    IF NOT FOUND OR existing.current_revision <> p_expected_revision THEN
        RAISE EXCEPTION 'Policy revision conflict';
    END IF;
    IF existing.worker_id <> p_worker_id OR existing.scope_id <> p_scope_id THEN
        RAISE EXCEPTION 'Worker and scope assignment cannot be changed in this prototype';
    END IF;
    next_revision := existing.current_revision + 1;
    INSERT INTO retention.policy_revisions (policy_id, revision, owner_name, document)
    VALUES (p_policy_id, next_revision, p_owner_name, p_document);
    UPDATE retention.policies SET current_revision = next_revision WHERE policy_id = p_policy_id;
    RETURN next_revision;
END;
$$;

CREATE FUNCTION retention.claim_report_run(
    p_policy_id uuid,
    p_worker_id uuid,
    p_expected_revision integer,
    p_lease_seconds integer DEFAULT 120
)
RETURNS TABLE (run_id uuid, lease_token uuid, lease_expires_at timestamptz, revision integer, document jsonb)
LANGUAGE plpgsql AS $$
DECLARE
    selected retention.policies%ROWTYPE;
    snapshot jsonb;
    new_run uuid := gen_random_uuid();
    new_token uuid := gen_random_uuid();
    expires timestamptz;
    target_scope uuid;
BEGIN
    IF p_lease_seconds IS NULL OR p_lease_seconds NOT BETWEEN 30 AND 900 THEN
        RAISE EXCEPTION 'Lease duration must be from 30 to 900 seconds';
    END IF;
    SELECT p.scope_id INTO target_scope FROM retention.policies p WHERE p.policy_id = p_policy_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Policy does not exist';
    END IF;
    PERFORM 1 FROM retention.scopes s WHERE s.scope_id = target_scope AND s.enabled FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Scope is disabled';
    END IF;
    PERFORM 1 FROM retention.workers w WHERE w.worker_id = p_worker_id AND w.enabled FOR SHARE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Worker is disabled';
    END IF;
    SELECT * INTO selected FROM retention.policies p WHERE p.policy_id = p_policy_id FOR UPDATE;
    IF selected.worker_id IS DISTINCT FROM p_worker_id OR selected.current_revision IS DISTINCT FROM p_expected_revision THEN
        RAISE EXCEPTION 'Worker assignment or revision conflict';
    END IF;
    SELECT r.document INTO snapshot FROM retention.policy_revisions r
        WHERE r.policy_id = p_policy_id AND r.revision = selected.current_revision;
    IF NOT (snapshot->>'enabled')::boolean THEN
        RAISE EXCEPTION 'Policy is disabled';
    END IF;
    PERFORM 1 FROM retention.runs r WHERE r.scope_id = selected.scope_id AND r.state IN ('Running', 'NeedsReview');
    IF FOUND THEN
        RAISE EXCEPTION 'Scope has an active or unresolved run; leases are not stolen automatically';
    END IF;
    expires := clock_timestamp() + make_interval(secs => p_lease_seconds);
    INSERT INTO retention.runs (run_id, policy_id, revision, worker_id, scope_id, state, lease_token, lease_expires_at)
    VALUES (new_run, selected.policy_id, selected.current_revision, p_worker_id, selected.scope_id, 'Running', new_token, expires);
    INSERT INTO retention.run_events (run_id, kind) VALUES (new_run, 'Claimed');
    RETURN QUERY SELECT new_run, new_token, expires, selected.current_revision, snapshot;
END;
$$;

CREATE FUNCTION retention.renew_report_run(p_run_id uuid, p_worker_id uuid, p_token uuid, p_lease_seconds integer DEFAULT 120)
RETURNS boolean LANGUAGE plpgsql AS $$
BEGIN
    IF p_lease_seconds IS NULL OR p_lease_seconds NOT BETWEEN 30 AND 900 THEN
        RAISE EXCEPTION 'Lease duration must be from 30 to 900 seconds';
    END IF;
    UPDATE retention.runs r
    SET lease_expires_at = clock_timestamp() + make_interval(secs => p_lease_seconds)
    FROM retention.policies p, retention.policy_revisions v, retention.workers w, retention.scopes s
    WHERE r.run_id = p_run_id AND r.worker_id = p_worker_id AND r.lease_token = p_token
        AND r.state = 'Running' AND r.lease_expires_at > clock_timestamp()
        AND p.policy_id = r.policy_id AND p.current_revision = r.revision
        AND v.policy_id = p.policy_id AND v.revision = p.current_revision AND (v.document->>'enabled')::boolean
        AND w.worker_id = r.worker_id AND w.enabled AND s.scope_id = r.scope_id AND s.enabled;
    RETURN FOUND;
END;
$$;

CREATE FUNCTION retention.complete_report_run(p_run_id uuid, p_worker_id uuid, p_token uuid, p_result jsonb)
RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE
    selected retention.runs%ROWTYPE;
    outcome text;
BEGIN
    IF p_result IS NULL OR jsonb_typeof(p_result) <> 'object' OR
        NOT (p_result ?& ARRAY['mode', 'status', 'deleted_count']) OR
        (p_result->>'mode') IS DISTINCT FROM 'ReportOnly' OR p_result->'deleted_count' <> '0'::jsonb THEN
        RAISE EXCEPTION 'Only report-only results with zero deletions are accepted';
    END IF;
    outcome := p_result->>'status';
    IF outcome IS NULL OR outcome NOT IN ('Completed', 'Partial', 'Failed', 'Disabled') THEN
        RAISE EXCEPTION 'Invalid report outcome';
    END IF;
    SELECT * INTO selected FROM retention.runs WHERE run_id = p_run_id FOR UPDATE;
    IF NOT FOUND OR selected.worker_id IS DISTINCT FROM p_worker_id OR selected.lease_token IS DISTINCT FROM p_token THEN
        RAISE EXCEPTION 'Run owner or token mismatch';
    END IF;
    IF selected.state IN ('Completed', 'Partial', 'Failed', 'Disabled') THEN
        IF selected.result = p_result THEN
            RETURN false;
        END IF;
        RAISE EXCEPTION 'Run already completed with a different result';
    END IF;
    IF selected.state <> 'Running' OR selected.lease_expires_at <= clock_timestamp() THEN
        RAISE EXCEPTION 'Expired or unresolved run cannot be completed by a worker';
    END IF;
    UPDATE retention.runs SET state = outcome, result = p_result, finished_at = clock_timestamp()
        WHERE run_id = p_run_id;
    INSERT INTO retention.run_events (run_id, kind) VALUES (p_run_id, 'Completed');
    RETURN true;
END;
$$;

CREATE FUNCTION retention.mark_expired_run(p_run_id uuid)
RETURNS boolean LANGUAGE plpgsql AS $$
BEGIN
    UPDATE retention.runs SET state = 'NeedsReview'
    WHERE run_id = p_run_id AND state = 'Running' AND lease_expires_at <= clock_timestamp();
    IF NOT FOUND THEN
        RETURN false;
    END IF;
    INSERT INTO retention.run_events (run_id, kind) VALUES (p_run_id, 'LeaseExpired');
    RETURN true;
END;
$$;

CREATE FUNCTION retention.resolve_run(p_run_id uuid, p_operator_name text, p_note text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF p_operator_name IS NULL OR btrim(p_operator_name) = '' OR p_note IS NULL OR btrim(p_note) = '' THEN
        RAISE EXCEPTION 'An operator and explicit reconciliation note are required';
    END IF;
    UPDATE retention.runs SET state = 'Resolved', finished_at = clock_timestamp(),
        resolution = jsonb_build_object('operator', p_operator_name, 'note', p_note)
    WHERE run_id = p_run_id AND state = 'NeedsReview';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Only a NeedsReview run may be reconciled';
    END IF;
    INSERT INTO retention.run_events (run_id, kind, detail)
    VALUES (p_run_id, 'OperatorResolved', jsonb_build_object('operator', p_operator_name, 'note', p_note));
END;
$$;

REVOKE ALL ON ALL TABLES IN SCHEMA retention FROM PUBLIC;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA retention FROM PUBLIC;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA retention FROM PUBLIC;
COMMIT;
