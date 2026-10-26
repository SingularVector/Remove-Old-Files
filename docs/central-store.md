# Central policy and run-history store: PostgreSQL prototype

Status: database-contract prototype. The PowerShell worker module is not connected to this store yet. Database claims accept report-only work; central deletion is not implemented. The existing CSV/local-policy commands continue unchanged and do not acquire database locks.

## Database decision

Use PostgreSQL as the initial central-store implementation. The requirement is a shared service for versioned policy publication, concurrent worker coordination and run history. PostgreSQL's transactions, row locks and constraints fit those requirements without choosing a Windows-only server environment.

SQLite remains useful for a local worker spool or isolated test data. Do not treat a SQLite file on an SMB/NFS share as the multi-worker central service. SQL Server would be a reasonable alternative in an environment already standardised on it, but no such requirement has been specified for this rebuild.

This choice introduces an operated service: backups, access control, TLS, monitoring and database upgrades are deployment requirements, not features this schema completes. The prototype tests database behaviour before adding a driver dependency or wiring SQL into cleanup.

Sources: [PostgreSQL locking](https://www.postgresql.org/docs/current/explicit-locking.html), [PostgreSQL constraints](https://www.postgresql.org/docs/current/ddl-constraints.html), [SQLite network-file caveats](https://www.sqlite.org/useovernet.html).

## What exists now

`database/postgresql/001_initial.sql` creates a new retention schema transactionally. It deliberately fails on a second installation rather than silently accepting a possibly different schema. It has not been applied to an existing user database.

| Entity | Purpose |
| --- | --- |
| workers | Enrolled worker IDs and enabled state |
| scopes | Administrator-defined shared-resource groups used to serialise claims |
| policies | Stable policy UUID, fixed worker/scope assignment and current revision |
| policy_revisions | Immutable owner, policy document and database publication time |
| runs | Claimed revision, worker, scope, report-only mode, lease and final result |
| run_events | Append-only claim, completion, expiry and reconciliation events |

A scope represents a resource boundary, not an automatically discovered root path. Policies touching the same underlying share or resource must share a scope, even when their paths use different aliases. The schema cannot infer physical identity from path strings. Different scopes do not protect overlapping physical resources from each other. Path/overlap validation remains necessary in the future control plane and worker.

Worker and scope assignment cannot be changed in-place by this prototype's publisher. Reassignment requires disabling/reconciling the old policy and a deliberate administrative workflow. It must not be inferred from the machine name at connection time.

## Publication and frozen revisions

`retention.publish_policy` takes the stable policy ID, expected current revision, worker/scope IDs, owner and JSON document. Revision zero means first publication. Updates must name the actual current revision, otherwise they conflict. Readers and runs retain their exact old revision even after later publication.

Database validation checks required fields, JSON types and the retention range. It does not replace the engine's complete path/pattern validation or prove a path exists. The worker must map the document to the existing policy model and validate it before filesystem access.

The document uses root_path, file_pattern, retention_days, recurse and enabled. This is the store schema, not a newly accepted format for the local cleanup command. There is no automatic CSV upload or database connection parameter in the module yet.

## Claim and outcome contract

| Function | Behaviour |
| --- | --- |
| claim_report_run | Requires an enabled scope/worker/policy, assigned worker and expected revision. Returns a new run ID, lease token, expiry and frozen document. |
| renew_report_run | Extends an unexpired run only for its worker/token while the current policy revision and enabled states still match. Otherwise returns false. |
| complete_report_run | Accepts only report-only results with zero deletions. The same completion retry is harmless; a different retry is rejected. |
| mark_expired_run | Changes an expired Running run to NeedsReview without releasing its scope. Repeated calls do not duplicate the event. |
| resolve_run | Requires an operator and reconciliation note; marks a NeedsReview run Resolved and records the operator action separately. |

Only one Running or NeedsReview run may occupy a scope. Publication and claiming use an explicit scope/worker/policy lock order. Claims and unique constraints are enforced by PostgreSQL, not by a read-then-write decision made independently by each worker.

Successful worker completions are Completed, Partial, Failed or Disabled. They are terminal snapshots. A new run receives a different run ID and token. These stored outcomes describe report work; they do not establish exactly-once filesystem operations.

## Why expired leases are not stolen

A database timeout does not prove a process stopped. Automatic takeover could allow an old process and its replacement to touch the same resource. The expired run therefore holds the scope until reconciliation.

NeedsReview is an unresolved state, not an automatic failure or permission to rerun. Before resolving it, an operator must establish that the previous worker is stopped/fenced and inspect the actual outcome. The required note records that decision; text in a note cannot itself prove that fencing occurred.

The current database interface permits reports only. Integrating deletion will require per-action claim checks, durable intent/outcome handling and explicit treatment of network partitions and uncertain results. A database lock cannot atomically lock arbitrary files on another server.

## Outages and identity boundaries

Future database-backed workers must stop before starting more central work if claims or renewals cannot be confirmed. Do not fall back silently to a cached policy for deletion. A local diagnostic/report-only mode can remain available with explicit local scope, but it must not be presented as a centrally coordinated run.

This prototype runs as the disposable database owner. Public schema/table/function privileges are revoked. Application roles, tenant separation and binding an authenticated principal to its worker ID are not implemented. A supplied worker ID or lease token is not a substitute for authentication. Before any real deployment, provision restricted publishing and worker roles or an authenticated service boundary, use TLS verification, and keep credentials/tokens out of logs.

New-LogEntry can record run IDs, policy/revision, status and storage failures at the runner boundary. Operational logs supplement stored outcomes; neither should claim a successful result when persistence failed. File paths and error details also need deliberate access and history-retention policies.

## Run the isolated database checks

Requirements: PowerShell 7.4+ and a running Docker engine. From the repository:

```powershell
./tools/Test-PostgreSqlStore.ps1
```

The tool starts the official `postgres:18-alpine` image with no network, no published ports, no host bind mounts and a memory-backed database. It applies the schema, runs the contract assertions and starts two competing PostgreSQL clients. Only the synthetic tables are touched. The container is removed in the final cleanup block, including on test failure. The image can remain in the local Docker cache.

This is a database test, not an installation of a central service. There are no production paths, real cleanup calls or database secrets in the fixtures. The report-only module can still be imported without Docker, a database driver or a database connection.

The test prints the server version and image ID with its results. The major-version image tag can move to a newer patch; pin an approved digest for an actual deployment. The schema and test are currently a fresh-database prototype, not an upgrade mechanism for deployed stores.

## Next integration milestone

After these contracts hold, add a parameterised PostgreSQL adapter and authenticated worker identity, then a report-only worker that claims a revision, maps/validates it, scans locally and completes the run. Keep those operations behind module internals and a small supported command surface. The existing local execution command must not silently become database-backed or gain a fallback that bypasses central coordination.

Do not write another blog post just for this schema. A later centralisation article earns its place when it can demonstrate a working report worker, coordination and useful history end to end.
