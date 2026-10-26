# Controlled single-policy cleanup

This development milestone adds `Invoke-RetentionCleanup`. Reporting remains the default. Deletion requires an explicit Execute switch and uses PowerShell's ShouldProcess confirmation. Only disposable fixtures have been used for local deletion tests; this is not a production deployment approval.

## Plan first

```powershell
$result = Invoke-RetentionCleanup -Policy $policy
$result.Status
$result.Actions
Export-RetentionReportHtml -Report $result.ScanReport -LiteralPath ./reports/review.html
```

The Policy object follows the existing strict engine contract. This command does not accept a saved report, arbitrary candidate paths or a CSV batch. Every invocation performs a fresh scan. Without Execute it does not remove files, even when candidates exist.

## Preview the execution path

```powershell
$preview = Invoke-RetentionCleanup -Policy $policy -Execute -WhatIf
$preview.Actions
```

Execute plus WhatIf validates the execution path and calls ShouldProcess without invoking removal. Mode is WhatIf and DeletedCount remains zero. Preview success does not prove the server will later permit deletion.

## Explicit execution

On an intentionally disposable scope, after reviewing the policy:

```powershell
$execution = Invoke-RetentionCleanup -Policy $policy -Execute
$execution | Select-Object Mode, Status, PlannedCount, DeletedCount, SkippedCount, ErrorCount
$execution.Actions
```

ConfirmImpact is High, so standard default confirmation preferences prompt per candidate. Caller preferences can affect prompts; use Confirm explicitly if needed. An unattended invocation can intentionally pass `-Confirm:$false`, but still requires Execute. The engine has no Force deletion option, does not recurse during removal, and never removes directories as a planned target.

Any scan that is Partial or Failed blocks all execution for this policy and returns Status=Blocked. Disabled policies remain Disabled. A Completed scan with zero candidates completes with zero removals.

## Fresh checks

Before asking for confirmation, and again after a positive confirmation, the engine checks:

- The path remains inside its normalised policy root and respects nonrecursive scope.
- Every ancestor is still an accessible directory without a link/reparse point.
- No regular ignore marker now protects the file's containing directory or any ancestor within the scope.
- The entry is still a regular file without a reparse point.
- Its observed length and last-write timestamp still match the scan, and its timestamp remains strictly earlier than that scan's cutoff.

Changed candidates are skipped with a reason. Unavailable metadata, failed marker checks, missing paths or removal errors produce failed actions; they are not counted as successful deletions. Other candidates can still proceed once the original complete scan has passed.

The filesystem is not locked. A replacement with identical length and timestamp may not be detected, and another process can change a path after the last check. These checks reduce ordinary operational surprises, not hostile concurrent replacement. Keep execution scopes and write access controlled. Old files may still be open or important to their application; age alone is not evidence otherwise.

## Interpret the result

The execution result contains Mode, Status, ScanReport and Actions. PlannedCount is the candidate count from the fresh scan. DeletedCount increases only after the removal command returns successfully; DeletedBytesObserved sums scan-time file lengths, not guaranteed freed space. SkippedCount includes declined, WhatIf and changed/protected candidates. ErrorCount counts execution errors; initial inspection errors remain in ScanReport.Errors.

Each action includes Path, Status, Reason and Message. A run with skipped changed/protected/declined candidates is Partial. Removal errors produce Partial when some deletion succeeded, otherwise Failed. A WhatIf preview without errors completes in its explicit WhatIf mode, with its actions marked skipped/WhatIf.

After Execute was requested, ScanReport.Mode is PreExecutionSnapshot, even for a blocked or preview run. The existing HTML exporter rejects it, so an execution snapshot cannot be rendered as a “no files deleted” receipt after actual removal. Export the read-only planning result before execution; retain the execution result itself as structured evidence, for example with `ConvertTo-Json -Depth 10`. A dedicated HTML execution receipt is not implemented in this milestone.

Automatic CSV batch deletion is also not implemented. The report-only batch remains available. Do not bypass its overlap validation by blindly iterating accepted rows from an invalid import.

## Evidence and limits

The local combined suite passed 99 checks with 3 platform-dependent skips on macOS, PowerShell 7.6.7 and Pester 5.7.1. Tests use disposable directories and cover real opt-in removal, read-only default, WhatIf, blocked incomplete scans, failure accounting, two fresh checks, changed files, new ignore markers and directory substitution. Mocks exercise failures and confirmation-time changes deterministically. This does not demonstrate Windows ACL, locked-file or network-share behaviour. Platform integration tests still need their appropriate hosts and fixtures.
