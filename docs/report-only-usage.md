# Report-only engine: first development milestone

The scanner is an alpha implementation that reads one policy and returns one report without changing input files. It does not invoke the legacy script. A separate, explicitly opted-in cleanup command is now described in [controlled cleanup](controlled-cleanup.md).

## Requirements and verification limits

- PowerShell 7.4 or later.
- Read access to the intended directory and any ancestor metadata needed for validation.
- An explicit absolute filesystem path; filesystem roots, link/reparse-point roots or ancestors, and parent-traversal (`..`) segments are rejected.

Local acceptance tests have been run on macOS with PowerShell 7.6.7 and Pester 5.7.1. Hosted Windows/Linux/macOS runs have passed for the pushed module milestone; see [verification evidence](verification.md) for exact totals and scope. Network-share access has not been verified. Windows junction tests require Windows; the UNC integration check remains explicitly skipped pending a controlled test share.

On macOS, use physical path spellings such as `/private/tmp/...` rather than `/tmp/...`, whose link ancestor is deliberately rejected. Filename/marker comparisons use ordinal case sensitivity on non-Windows hosts, even on a case-insensitive filesystem.

## Try one policy

From the repository directory:

```powershell
Import-Module ./src/RetentionEngine/RetentionEngine.psd1 -Force

$policy = [pscustomobject](
    @{
        PolicyId = 'automation-logs'
        RootPath = 'C:\RetentionLab' # Replace with an existing disposable directory.
        FilePattern = '*.log'
        RetentionDays = 30
        Recurse = $true
        Enabled = $true
    }
)

$report = Get-RetentionReport -Policy $policy
$report | Select-Object Status, CandidateCount, CandidateBytes, ErrorCount, DeletedCount
$report.Candidates
$report.Exclusions
$report.Errors
```

On Linux, a suitable example root is `/home/your-user/retention-lab`; on macOS, `/Users/your-user/retention-lab`. Create the directory yourself before scanning it. The function neither creates roots nor changes input files.

The report includes native PowerShell objects, Boolean flags, numeric lengths and UTC timestamps. Use `ConvertTo-Json -Depth 8` or your preferred export outside the engine. Output files and log locations should be outside any future cleanup scope.

## Read the status, not just the candidates

| Status | Meaning |
| --- | --- |
| Completed | Intended inspection completed without errors; zero matches is valid. Protected directories and skipped links are reported exclusions. |
| Partial | Some intended inspection failed; available candidates are not a complete inventory. |
| Failed | Policy validation or initial root access prevented scanning. |
| Disabled | Structurally valid disabled policy; root was not accessed. |

An `ignore` regular file protects its containing directory and entire subtree. Links and reparse points are not followed. Exclusion counts describe entries actually observed, never the unseen contents of a protected subtree.

Retention uses `LastWriteTimeUtc` strictly earlier than the run's cutoff. Files exactly at that cutoff are excluded. The scan is not a transactional snapshot, and an old file is not necessarily safe for its application to lose. Do not pass report candidates into an ad hoc deletion pipeline.

To reproduce a boundary decision, supply an explicit instant:

```powershell
$report = Get-RetentionReport -Policy $policy -EvaluationTimeUtc ([datetimeoffset]'2026-10-26T12:00:00Z')
```

## Export a readable HTML report

The scanner keeps returning structured objects. A separate exporter writes an explicit output file:

```powershell
Export-RetentionReportHtml -Report $report -LiteralPath ./retention-report.html
```

Choose an existing directory outside the scanned root. Relative output paths use your current PowerShell location. Output must end in `.html` or `.htm`. The exporter rejects parent-traversal segments, link/reparse-point destinations or ancestors, and non-filesystem providers. On macOS it conservatively compares scope paths without case to protect case-insensitive volumes.

The HTML embeds its CSS and uses no external scripts, fonts or libraries. It includes the outcome, effective policy and cutoff, candidate counts and observed bytes, candidate details, exclusions and errors. Partial, failed and disabled scans are labelled explicitly rather than presented as successful empty inventories. All supplied rows are included; very large scans can produce correspondingly large reports. Potential bytes are observed file lengths, not guaranteed disk-space savings.

Existing files are protected. Use `-Force` to replace an existing regular report, `-WhatIf` to preview the output operation, and optionally `-ReportLabel 'Review copy'` for extra context. The exporter returns the output path, run identifier and status; it does not modify the source report or scanned files. Text from policies, paths and diagnostics is HTML-escaped. Review the report before sharing it, since its paths and errors may disclose internal details.

Output is written completely to a unique temporary file in the destination directory, then moved into place. A failed replacement leaves an existing destination intact and cleans up the temporary file. Ancestor checks are ordinary path checks, not a guarantee against hostile concurrent directory replacement. A failed export raises an error independently of scan status.

A [synthetic sample](../examples/sample-retention-report.html) illustrates a partial scan; its paths, counts and timestamps are invented. Recreate it from the repository directory:

```powershell
./examples/New-SampleRetentionReport.ps1 -LiteralPath ./examples/sample-retention-report.html -Force
```

The sample generator never scans a real log directory. It labels the report as a demonstration and does not imply production savings.

## Run the acceptance tests

Install Pester 5.7.1 if needed, then from this repository run:

```powershell
Import-Module Pester -RequiredVersion 5.7.1
$result = Invoke-Pester -Path ./tests -Output Detailed -PassThru
if ($result.FailedCount -gt 0 -or $result.Result -ne 'Passed') { throw 'Retention tests failed.' }
```

Tests create disposable fixtures and never run `Remove-OldFiles.ps1`. Directory/metadata failure tests mock the small filesystem boundaries deliberately; they are not evidence of real SMB permissions behaviour. Tests that require unavailable platform facilities report skips.

Legacy CSV import and multi-policy reporting are now available; see [CSV migration](csv-migration.md). Opt-in single-policy deletion is described in [controlled cleanup](controlled-cleanup.md). Automatic batch deletion, notifications and database storage are not implemented.
