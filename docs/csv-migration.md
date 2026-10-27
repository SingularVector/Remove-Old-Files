# Legacy CSV migration and multi-policy reports

This milestone imports the original four-column policy format and runs report-only scans. These CSV commands do not delete files; a separate opt-in single-policy command is described in [controlled cleanup](controlled-cleanup.md). The original `FilePaths.csv` and `Remove-OldFiles.ps1` are preserved unchanged.

## Inspect before scanning

```powershell
Import-Module ./src/RetentionEngine/RetentionEngine.psd1 -Force
$import = Import-RetentionPolicyCsv -LiteralPath ./FilePaths.csv
$import | Select-Object Status, IsReady, RecordCount
$import.Policies
$import.Warnings
$import.Errors
$import.Overlaps
```

Import reads the CSV but does not inspect its target directories. `Ready`/IsReady=true means structural validation passed with no invalid rows or overlapping roots; it is not evidence that paths exist or that access is permitted. Any validation error or overlap produces `Invalid`/IsReady=false. Accepted rows remain available for review but do not authorise a partial batch.

Only the four legacy headers are accepted, in any order, with case-insensitive names and trimmed surrounding whitespace. Missing, duplicate and unknown headers fail the file. Quoted fields, embedded commas, BOM-identified text encodings and blank lines are handled by the CSV parser. Each nonblank data record must have exactly four fields, including explicit empty cells. Malformed quoting blocks the file.

| CSV field | Policy value and rules |
| --- | --- |
| CleanupPath | Absolute RootPath, validated structurally using the engine's disabled-policy path. Missing/relative/root/device paths and parent-traversal segments are rejected. |
| FileExtension | A bare extension such as `log` or `tar.gz` becomes `*.log` or `*.tar.gz`. Wildcards, path separators and leading dots are rejected. An empty cell becomes explicit `*`, with a warning that extensionless files also match. |
| AgeTolerance | Whole-number digits from 1 to 36500. Empty means 90 with a warning. Negative, decimal, overflowing and out-of-range values fail the row. |
| IncludeSubFolders | `0` means false, `1` means true. Empty means false with a warning. Other values are rejected. |

All values are trimmed. Imported policies are enabled because the legacy schema has no enabled column; an added Enabled column is rejected rather than silently ignored. Generated IDs (`csv-row-2`, etc.) refer to data-record positions starting after the header. SourceFile, SourceRow and SourceLine identify the source. These are not stable policy identities across reordering; use source plus row when correlating imports from multiple files.

The original UNC sample is Windows configuration. The supported target is Windows only; CSV import remains a legacy migration utility rather than the intended SQL configuration source.

## Overlap policy

Equal or nested normalised roots conflict, regardless of file pattern or recursion setting. This is intentionally conservative: the importer does not guess precedence or attempt to prove that two wildcard filters are disjoint. Similar sibling prefixes such as `logs` and `logs-archive` are not nested scopes. Scope comparisons are case-insensitive on the supported Windows target.

Overlaps include both policy IDs, both row numbers and SameRoot/NestedRoots. They are exposed separately from parsing errors, and either blocks batch scanning. Consolidate or reorganise policies deliberately before scanning; do not silently discard a duplicate row. More flexible precedence and pattern interaction are future design work.

The repository's original sample includes two rows for the same archive path. They are retained as historical input and will be flagged as an overlap on a compatible Windows host.

## Run a validated batch

```powershell
$batch = Get-RetentionBatchReport -LiteralPath ./my-policies.csv
$batch.Status
$batch.Import.Errors
$batch.Import.Overlaps
$batch.Reports | Select-Object PolicyId, Status, CandidateCount, ErrorCount
```

The batch imports and validates the entire file before scanning any root; there is no allow-invalid-rows switch. Every policy uses one evaluation instant, with its own retention cutoff. An optional EvaluationTimeUtc parameter makes this repeatable.

If import fails, Status is Failed and Reports is empty. Once import succeeds, each root is scanned independently: all Completed results produce a Completed batch; mixed success/failure or any partial inspection produces Partial; if every scan fails, the batch is Failed. Errors remain in each report as well as import diagnostics. DeletedCount is always zero.

Existing HTML export accepts a single scan result, not the batch envelope. Keep outputs outside all configured scan roots, using a separate existing reporting directory:

```powershell
foreach ($report in $batch.Reports)
{
    $output = Join-Path ./reports ($report.PolicyId + '.html')
    Export-RetentionReportHtml -Report $report -LiteralPath $output
}
```

The importer-generated IDs are filename-safe for this example; do not generalise that assumption to arbitrary external policy IDs. Existing output files still require Force. A consolidated batch HTML page is not part of this milestone.

## Verification evidence

The local combined Pester run passed 86 tests, with 3 platform-dependent skips, on macOS/PowerShell 7.6.7/Pester 5.7.1. The 25 new checks cover conversions, defaults, quoting, malformed rows and headers, no-target-I/O import, overlap gating and real disposable batch scans. Existing scanner and exporter tests also passed.

The three skips concern Windows path validation, junctions and a provisioned UNC share. Do not infer Windows/Linux or network-share verification from this local run. CI now targets Windows only. Earlier cross-platform fixture runs remain historical evidence.
