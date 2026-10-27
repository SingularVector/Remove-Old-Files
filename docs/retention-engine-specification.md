# Retention engine: behaviour specification

Status: scanner behaviour baseline. The current deployment scope is Windows only, SQL Server with integrated authentication by default or an optional SQL credential and one rules table; see [SQL Server jobs](sqlserver-jobs.md). Earlier coordination/database prototype ideas are superseded. Internal policy objects below describe the scanner interface, not additional database tables.

## Problem and scope

The original solution addressed accumulated logs from multiple automations, each with its own retention requirements, and cleanup requests from other teams. The rebuilt engine must apply those different policies predictably and explain what it inspected, excluded, selected and failed to inspect.

Development stays in this repository, preserving its history. The existing script and CSV remain unchanged during the first milestone. The rebuilt engine is a future major version; its behaviour must not be presented as a drop-in replacement for the legacy implementation.

The first milestone loads one explicit policy, scans a directory and returns a structured report. It does not delete files, change permissions, create marker files, send email or connect to a database. Filesystem reads may have normal operating-system metadata effects, such as access-time updates.

Windows with PowerShell 7.4 or later is the supported baseline. Filesystem behaviour must be verified on Windows. UNC paths are supported on Windows subject to the execution account's access. Network failures must be reported distinctly from an empty successful scan. Do not claim portability or network-filesystem support based only on local tests.

## Policy contract

| Field | Meaning | Validation |
| --- | --- | --- |
| PolicyId | Stable identifier for reporting and later history | Required nonempty string |
| RootPath | Directory to inspect | Required absolute local path, or UNC path on Windows; reject filesystem roots and non-filesystem providers |
| FilePattern | Filename pattern, independent of directory path | Required; support `*` and `?` wildcards only; reject path separators and bracket patterns |
| RetentionDays | Age threshold in whole days | Required integer from 1 through 36500 |
| Recurse | Whether to visit child directories | Explicit Boolean; no truthiness conversion of strings |
| Enabled | Whether the policy may run | Explicit Boolean |

Paths containing a parent-traversal (`..`) segment are rejected before normalisation so that a link ancestor cannot be hidden by lexical path collapse.

The initial engine accepts one policy object. CSV import and batch execution are subsequent milestones. Normalisation must not mutate the caller's policy object.

Use case-insensitive filename matching on Windows. Hidden files and directories are included unless excluded by an ignore marker or link rule. Only regular files are candidates; directories are never deletion targets.

A disabled, structurally valid policy returns `Disabled` without accessing its root. Structural validation happens before filesystem traversal. Invalid policies produce a validation failure and no scan; values that broaden the scope must never be substituted for invalid input.

## Age calculation

- Capture one UTC evaluation time at the start of the run. Accept an injectable clock for repeatable tests.
- Compute `CutoffUtc = EvaluationTimeUtc.AddDays(-RetentionDays)` once.
- Select a file only when `LastWriteTimeUtc < CutoffUtc`. A timestamp exactly at the cutoff does not qualify.
- Use last-write time, not creation time or last-access time. Record the selected basis explicitly.
- A future timestamp is not eligible. Reject an evaluation time/retention combination that cannot produce a valid cutoff.

The engine reports what it observed during the scan. It does not promise a transactional filesystem snapshot or that an old file is unused, closed or safe for its application to lose.

## Traversal and exclusions

1. Validate and normalise the root, preserving the original input in the report. Treat it as a literal path, never a wildcard expression.
2. Reject a root that is a file, a symbolic link, a junction or another reparse point. Reject paths with link/reparse-point ancestors as well; record an error if ancestry cannot be checked.
3. Before processing a directory, check for a regular file named `ignore`, using platform-appropriate case matching. The name is fixed in the first milestone.
4. An ignore marker protects that directory and its entire subtree, regardless of file age or pattern. A marker at the root excludes the whole scope.
5. Do not descend into a protected directory, including to count its files. Report the excluded directory and reason, not an invented count of excluded descendants. The marker is never a candidate.
6. Skip symbolic links, junctions and other reparse points encountered during enumeration. Do not follow their targets, including targets inside the root. Report the skipped entry and reason.
7. With `Recurse = false`, inspect only files directly inside the root. Record child directories as excluded by the nonrecursive policy, without traversing them.
8. A failure to check markers or enumerate a directory means that directory is not safe to inspect further. Report the failure and skip its subtree. Other accessible sibling directories may still be inspected.
9. A file metadata failure produces an error for that entry; it must not become an eligible candidate through missing/default timestamps.

Use a directory-by-directory walker rather than recursively listing everything and filtering exclusions afterwards. Normalise paths and compare directory boundaries; a prefix such as `Archive` must not accidentally match `ArchiveOld`.

These are ordinary traversal boundaries, not a guarantee against hostile concurrent replacement of directories. Later destructive execution requires fresh checks and a documented residual race limitation.

## Report contract

Return one structured run result. Do not mix formatted tables or diagnostic strings into the result stream. Optional verbose messages remain on the verbose stream; callers choose formatting and persistence.

The result contains:

- RunId, PolicyId, mode (`ReportOnly`), engine version and execution host.
- Original root, normalised root, effective policy, UTC evaluation time, cutoff and start/end timestamps.
- Status: `Completed`, `Partial`, `Failed` or `Disabled`.
- Candidate records: full literal path, byte length, last-write timestamp and selection reason.
- Exclusion records for observed entries: path and reason, such as `IgnoreMarker`, `LinkOrReparsePoint`, `RecursionDisabled`, `PatternMismatch` or `NotOldEnough`.
- Error records: affected path, operation, error category and message.
- Counts of inspected regular files, candidates, observed excluded entries and errors; candidate bytes total. These are observation counts, not a census of unvisited subtrees.
- DeletedCount, always zero in this milestone.

Each inspected regular file is classified once as a candidate or a file exclusion; entries whose required metadata cannot be read are errors instead. Directory exclusions and skipped links are counted separately from inspected regular files, even if the result exposes an aggregate exclusion count.

`Completed` means the intended traversal completed without errors, even when no candidates exist or an ignore marker excludes the entire scope. Exclusions alone do not make a run partial. `Partial` means a valid root was accessible but some intended inspection failed. `Failed` means validation or initial root access prevented scanning. Candidates in a partial report remain visible with its partial status; they must never be presented as a complete inventory.

Sort candidate, exclusion and error collections deterministically by path and then reason/operation for repeatable output. Retain native numeric, Boolean and timestamp types in PowerShell objects. JSON conversion is a caller/export concern for the first milestone.

No command-line exit-code contract is imposed on a reusable function. A future executable wrapper must map unsuccessful and partial results to documented nonzero statuses.

## HTML presentation boundary

The report-only scanner remains independent of output formatting. `Export-RetentionReportHtml` accepts one result and writes a standalone UTF-8 HTML file with embedded CSS, without remote assets or scripts. It retains policy context, exact UTC cutoff, candidate metadata, exclusions, errors and an unmistakable run outcome. Every supplied row is included. An optional report label is escaped like all other data.

Destination selection is explicit, outside the scanned root, with an existing parent directory. Existing regular outputs require Force; links/reparse-point destinations and ancestors are rejected. WhatIf must produce no output writes. Invalid report shapes/statuses or row/count mismatches fail before writing. Export errors must not alter the scan result. Temporary output is moved into place only when fully written, preserving an existing file on a failed replacement.

The report states that no files were deleted and that candidate bytes are an observation, not guaranteed space savings. Partial results must never look like a complete inventory. Synthetic examples must be labelled as such. This exporter is an addition to the first reporting milestone, not a database, notification or execution feature.

## CSV migration requirements

Retain the original `CleanupPath`, `FileExtension`, `AgeTolerance` and `IncludeSubFolders` headers in a later importer. The importer emits the same policy model used by the engine.

| Legacy value | Import behaviour |
| --- | --- |
| CleanupPath | Map to RootPath; validate normally |
| Bare extension such as `log` | Map to `*.log`; reject unsupported wildcard/path syntax |
| Empty FileExtension | Map to explicit `*`; emit a warning that all filenames, including extensionless ones, match |
| Empty AgeTolerance | Map to 90 days and report the applied default |
| IncludeSubFolders `0` | Map to false |
| IncludeSubFolders `1` | Map to true |
| Empty IncludeSubFolders | Map to false and report the applied default |
| Any other recursion value, invalid age or missing path | Reject the row; do not guess |

Trim field whitespace before conversion. Missing required headers are a file-level validation error. Legacy rows receive Enabled=true and an importer-generated identifier; until explicit identifiers are added, report source file and row number and do not claim identity persists across reordering.

This deliberately corrects the existing implementation, which treats every nonempty recursion value as enabled. Compatibility means an explainable migration, not preserving accidental behaviour. Overlapping/duplicate roots and policies must be detected before adding any batch deletion mode; do not invent deletion precedence during import.

## CSV and batch implementation decisions

The importer accepts only the four legacy headers, rejecting unknown/duplicate headers and wrong column counts rather than ignoring possible settings. It preserves source file, data-record ordinal and physical source line. Structural validation reuses a disabled copy of the policy so target directories are not accessed during import.

Import results retain accepted policies, warnings, row/file errors and overlap pairs. Any invalid row, malformed file or equal/nested normalised root makes the entire import not ready for batch execution. Nested roots are conservatively blocked even with nonrecursive policies or differing filters; pattern precedence is not inferred. Similar sibling prefixes do not conflict.

A batch reimports the complete CSV, scans only a ready import, uses one evaluation instant and returns individual report objects. Runtime failures are retained with successful sibling results; invalid configuration blocks all scanning. HTML export remains per-policy. See [CSV migration](csv-migration.md) for the executable interface and measured test evidence.

## Acceptance checks for the first milestone

All fixtures use disposable directories. No test targets real log locations or runs the legacy cleanup script.

| Scenario | Required result |
| --- | --- |
| Matching file older than cutoff | Candidate with correct metadata |
| Matching file exactly at cutoff | Excluded as NotOldEnough |
| Matching file newer than cutoff or future-dated | Excluded as NotOldEnough |
| Old file with a different filename | Excluded as PatternMismatch |
| Nonrecursive policy with an eligible nested file | Child directory excluded; nested file not visited |
| Recursive policy with that nested file | File is a candidate |
| Ignore marker in root | Completed report, zero candidates, root exclusion |
| Ignore marker in child directory | Child and all descendants unvisited; siblings still inspected |
| Marker-check permission failure | Error and subtree skipped, never treated as unprotected |
| Link/junction inside root | Skipped; no target traversal |
| Root or root ancestor is a link/junction | Failed before traversal |
| Similar prefixes: Archive and ArchiveOld | Excluding one does not exclude the other |
| Missing/inaccessible root, or root is a file | Failed report, not an empty Completed result |
| Child enumeration or metadata failure | Partial report with error and accurate remaining results |
| Valid disabled policy with unavailable root | Disabled result with no root access |
| Invalid policy, relative/root path or unsupported provider | Failed validation; no traversal |
| Hidden file and filename case differences | Documented platform matching and hidden-file behaviour |
| Repeated scan with a fixed clock and unchanged fixture | Same classifications and ordering; unique run metadata may differ |
| Any report-only run | File contents and last-write timestamps unchanged; DeletedCount=0 |

Use Pester for engine behaviour tests. Permission failures require either a reproducible unprivileged integration fixture or a controlled filesystem adapter in tests; do not count a permissions test as passed simply because it runs under an account that bypasses the restriction. Link/junction and UNC integration checks must state their actual platform prerequisites and be reported as skipped when unavailable.

## Controlled execution milestone

`Invoke-RetentionCleanup` accepts one policy and creates a fresh scan. It plans by default; Execute is mandatory for removal. Partial/failed inspection blocks the policy. A candidate is rechecked before confirmation and again afterwards for containment, ancestor type, ignore markers, file type, timestamp and length. Declined or changed candidates are skipped. Errors are retained as actions, and deletion counts advance only on successful removal.

Execution never consumes a saved candidate list. The execution result is a distinct receipt, and its scan snapshot is explicitly marked so that the no-deletion HTML exporter rejects it. There is no automatic CSV batch deletion yet. See [controlled cleanup](controlled-cleanup.md) for the full interface and residual filesystem race limits.

## Later milestones

1. Implement and verify the report-only engine defined above.
2. Add the CSV importer and multi-policy reporting with explicit overlap handling.
3. Add separately opted-in execution, guarded by ShouldProcess. Recheck containment, exclusions and candidate metadata before deletion; count success only after confirmed completion. A stored report is evidence, not a permanently valid deletion authorisation.
4. Read enabled rules for an explicitly configured JobName from one SQL Server table and update the last execution date, exception flag and actual machine name per rule. Scheduling and duplicate-job prevention remain configuration responsibilities; no worker registry, claims, leases or historical run tables are planned.

Email integration, a management interface, distributed scheduling and database credentials are outside the first milestone. The article can document observed behaviour and tested decisions as the project develops.
