CREATE TEMP TABLE contract_checks (name text PRIMARY KEY);

CREATE FUNCTION pg_temp.assert_true(condition boolean, label text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF condition IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'Contract assertion failed: %', label;
    END IF;
    INSERT INTO contract_checks VALUES (label);
END;
$$;

CREATE FUNCTION pg_temp.expect_error(statement text, label text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    failed boolean := false;
BEGIN
    BEGIN
        EXECUTE statement;
    EXCEPTION WHEN OTHERS THEN
        failed := true;
    END;
    PERFORM pg_temp.assert_true(failed, label);
END;
$$;

INSERT INTO retention.workers (worker_id, name) VALUES
    ('00000000-0000-0000-0000-000000000001', 'sample-worker-a'),
    ('00000000-0000-0000-0000-000000000002', 'sample-worker-b');
INSERT INTO retention.scopes (scope_id, name) VALUES
    ('00000000-0000-0000-0000-000000000001', 'sample-storage-a'),
    ('00000000-0000-0000-0000-000000000004', 'concurrency-fixture');

SELECT pg_temp.assert_true(retention.publish_policy(
    '00000000-0000-0000-0000-000000000001', 0,
    '00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001',
    'example-owner', '{"root_path":"/example/logs","file_pattern":"*.log","retention_days":90,"recurse":true,"enabled":true}') = 1,
    'initial policy revision');

SELECT pg_temp.expect_error($test$
    SELECT retention.publish_policy('00000000-0000-0000-0000-000000000001', 0,
        '00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001', 'owner',
        '{"root_path":"/example/logs","file_pattern":"*.log","retention_days":90,"recurse":true,"enabled":true}')
$test$, 'stale policy write rejected');

SELECT pg_temp.expect_error($test$
    SELECT retention.publish_policy('00000000-0000-0000-0000-000000000001', 1,
        '00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001', 'owner',
        '{"root_path":"/example/logs","file_pattern":"*.log","retention_days":90,"recurse":"0","enabled":true}')
$test$, 'policy Boolean strings rejected');

SELECT pg_temp.expect_error($test$
    UPDATE retention.policy_revisions SET owner_name = 'rewritten'
    WHERE policy_id = '00000000-0000-0000-0000-000000000001'
$test$, 'policy revision cannot be rewritten');

SELECT pg_temp.expect_error($test$
    SELECT retention.claim_report_run('00000000-0000-0000-0000-000000000001',
        '00000000-0000-0000-0000-000000000002', 1)
$test$, 'unassigned worker rejected');

SELECT pg_temp.expect_error($test$
    SELECT retention.claim_report_run('00000000-0000-0000-0000-000000000001',
        '00000000-0000-0000-0000-000000000001', 9)
$test$, 'stale claim revision rejected');

UPDATE retention.workers SET enabled = false WHERE worker_id = '00000000-0000-0000-0000-000000000001';
SELECT pg_temp.expect_error($test$
    SELECT retention.claim_report_run('00000000-0000-0000-0000-000000000001',
        '00000000-0000-0000-0000-000000000001', 1)
$test$, 'disabled worker rejected');
UPDATE retention.workers SET enabled = true WHERE worker_id = '00000000-0000-0000-0000-000000000001';

UPDATE retention.scopes SET enabled = false WHERE scope_id = '00000000-0000-0000-0000-000000000001';
SELECT pg_temp.expect_error($test$
    SELECT retention.claim_report_run('00000000-0000-0000-0000-000000000001',
        '00000000-0000-0000-0000-000000000001', 1)
$test$, 'disabled scope rejected');
UPDATE retention.scopes SET enabled = true WHERE scope_id = '00000000-0000-0000-0000-000000000001';

SELECT retention.publish_policy('00000000-0000-0000-0000-000000000001', 1,
    '00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001', 'owner',
    '{"root_path":"/example/logs","file_pattern":"*.log","retention_days":90,"recurse":true,"enabled":false}');
SELECT pg_temp.expect_error($test$
    SELECT retention.claim_report_run('00000000-0000-0000-0000-000000000001',
        '00000000-0000-0000-0000-000000000001', 2)
$test$, 'disabled policy rejected');
SELECT retention.publish_policy('00000000-0000-0000-0000-000000000001', 2,
    '00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001', 'owner',
    '{"root_path":"/example/logs","file_pattern":"*.log","retention_days":90,"recurse":true,"enabled":true}');

CREATE TEMP TABLE first_claim AS SELECT * FROM retention.claim_report_run(
    '00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001', 3);
SELECT pg_temp.assert_true((SELECT count(*) = 1 AND min(revision) = 3 FROM first_claim), 'claim returns frozen policy revision');
SELECT pg_temp.expect_error($test$
    SELECT retention.claim_report_run('00000000-0000-0000-0000-000000000001',
        '00000000-0000-0000-0000-000000000001', 3)
$test$, 'second active claim rejected');

SELECT retention.publish_policy('00000000-0000-0000-0000-000000000002', 0,
    '00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001', 'owner',
    '{"root_path":"/example/other-policy","file_pattern":"*.txt","retention_days":30,"recurse":false,"enabled":true}');
SELECT pg_temp.expect_error($test$
    SELECT retention.claim_report_run('00000000-0000-0000-0000-000000000002',
        '00000000-0000-0000-0000-000000000001', 1)
$test$, 'different policies sharing a scope cannot run together');
SELECT pg_temp.expect_error($test$
    UPDATE retention.run_events SET kind = 'rewritten'
$test$, 'history events cannot be rewritten');

SELECT pg_temp.assert_true(NOT retention.renew_report_run(run_id,
    '00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000099'), 'wrong lease token cannot renew') FROM first_claim;
SELECT pg_temp.assert_true(retention.renew_report_run(run_id,
    '00000000-0000-0000-0000-000000000001', lease_token), 'current worker can renew') FROM first_claim;

SELECT retention.publish_policy('00000000-0000-0000-0000-000000000001', 3,
    '00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001', 'owner',
    '{"root_path":"/example/logs","file_pattern":"*.log","retention_days":45,"recurse":true,"enabled":true}');
SELECT pg_temp.assert_true(NOT retention.renew_report_run(run_id,
    '00000000-0000-0000-0000-000000000001', lease_token), 'changed revision stops renewal') FROM first_claim;
SELECT pg_temp.assert_true((SELECT (document->>'retention_days')::integer = 90 FROM first_claim), 'claimed snapshot survives later edits');
SELECT pg_temp.assert_true(retention.complete_report_run(run_id,
    '00000000-0000-0000-0000-000000000001', lease_token,
    '{"mode":"ReportOnly","status":"Completed","deleted_count":0}'), 'completion recorded once') FROM first_claim;
SELECT pg_temp.assert_true(NOT retention.complete_report_run(run_id,
    '00000000-0000-0000-0000-000000000001', lease_token,
    '{"mode":"ReportOnly","status":"Completed","deleted_count":0}'), 'identical completion retry is idempotent') FROM first_claim;
SELECT pg_temp.expect_error(format($test$
    SELECT retention.complete_report_run(%L, '00000000-0000-0000-0000-000000000001', %L,
        '{"mode":"ReportOnly","status":"Failed","deleted_count":0}')
$test$, run_id, lease_token), 'conflicting completion retry rejected') FROM first_claim;

CREATE TEMP TABLE expired_claim AS SELECT * FROM retention.claim_report_run(
    '00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001', 4);
SELECT pg_temp.expect_error(format($test$
    SELECT retention.complete_report_run(%L, '00000000-0000-0000-0000-000000000001', %L,
        '{"mode":"Execute","status":"Completed","deleted_count":1}')
$test$, run_id, lease_token), 'central deletion results rejected') FROM expired_claim;
SELECT pg_temp.expect_error(format($test$
    SELECT retention.complete_report_run(%L, '00000000-0000-0000-0000-000000000001', %L,
        '{"mode":null,"status":"Completed","deleted_count":0}')
$test$, run_id, lease_token), 'null result mode rejected') FROM expired_claim;

UPDATE retention.runs SET lease_expires_at = clock_timestamp() - interval '1 second'
    WHERE run_id = (SELECT run_id FROM expired_claim);
SELECT pg_temp.assert_true(NOT retention.renew_report_run(run_id,
    '00000000-0000-0000-0000-000000000001', lease_token), 'expired lease cannot renew') FROM expired_claim;
SELECT pg_temp.expect_error($test$
    SELECT retention.claim_report_run('00000000-0000-0000-0000-000000000001',
        '00000000-0000-0000-0000-000000000001', 4)
$test$, 'expired run is not automatically stolen');
SELECT pg_temp.expect_error(format($test$
    SELECT retention.complete_report_run(%L, '00000000-0000-0000-0000-000000000001', %L,
        '{"mode":"ReportOnly","status":"Completed","deleted_count":0}')
$test$, run_id, lease_token), 'expired worker cannot complete') FROM expired_claim;
SELECT pg_temp.assert_true(retention.mark_expired_run(run_id), 'expiry moves run to review') FROM expired_claim;
SELECT pg_temp.assert_true(NOT retention.mark_expired_run(run_id), 'repeated expiry does not duplicate events') FROM expired_claim;
SELECT pg_temp.expect_error($test$
    SELECT retention.claim_report_run('00000000-0000-0000-0000-000000000001',
        '00000000-0000-0000-0000-000000000001', 4)
$test$, 'unresolved review holds scope');
SELECT pg_temp.expect_error(format('SELECT retention.resolve_run(%L, %L, %L)', run_id, '', ''),
    'resolution requires operator and note') FROM expired_claim;
SELECT retention.resolve_run(run_id, 'example-operator', 'Confirmed sample worker stopped; inspection reconciled.') FROM expired_claim;
SELECT pg_temp.assert_true((SELECT state = 'Resolved' AND resolution->>'operator' = 'example-operator'
    FROM retention.runs WHERE run_id = (SELECT run_id FROM expired_claim)), 'operator reconciliation is recorded separately');
SELECT pg_temp.expect_error(format($test$
    SELECT retention.complete_report_run(%L, '00000000-0000-0000-0000-000000000001', %L,
        '{"mode":"ReportOnly","status":"Completed","deleted_count":0}')
$test$, run_id, lease_token), 'reconciled run rejects stale completion') FROM expired_claim;

CREATE TEMP TABLE new_claim AS SELECT * FROM retention.claim_report_run(
    '00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001', 4);
SELECT pg_temp.assert_true((SELECT n.run_id <> e.run_id AND n.lease_token <> e.lease_token FROM new_claim n, expired_claim e), 'new claim has new identity and token');
SELECT retention.complete_report_run(run_id, '00000000-0000-0000-0000-000000000001', lease_token,
    '{"mode":"ReportOnly","status":"Failed","deleted_count":0}') FROM new_claim;
SELECT pg_temp.assert_true(NOT EXISTS (SELECT 1 FROM retention.run_events WHERE run_id = (SELECT run_id FROM expired_claim) AND kind = 'Completed'),
    'resolution does not fabricate a worker completion');
SELECT pg_temp.assert_true((SELECT count(*) = 3 FROM retention.run_events WHERE run_id = (SELECT run_id FROM expired_claim)),
    'claim expiry and resolution retain distinct events');

-- The following scope is reserved for two genuinely concurrent client sessions.
SELECT retention.publish_policy('00000000-0000-0000-0000-000000000004', 0,
    '00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000004', 'owner',
    '{"root_path":"/example/concurrency","file_pattern":"*.log","retention_days":30,"recurse":true,"enabled":true}');
SELECT 'DATABASE_ASSERTIONS_PASSED=' || count(*) FROM contract_checks;
