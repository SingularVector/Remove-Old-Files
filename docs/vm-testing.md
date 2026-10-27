# Try the cleanup module in a Windows VM

This lab creates real, small files with synthetic contents and controlled LastWriteTimeUtc timestamps. It does not contact SQL Server, change the system clock, schedule anything or run cleanup. Start with Windows x64 and PowerShell 7.4 or later. Copy or clone the repository into the VM and open PowerShell in its root directory. Generate the data inside the VM so the paths and timestamps are correct there.

## Create the lab

Choose a directory that does not already exist:

```powershell
Import-Module ./src/RetentionEngine/RetentionEngine.psd1 -Force
$lab = ./examples/New-RetentionTestData.ps1 -LiteralPath 'C:\RetentionLab'
$lab.Inventory | Format-Table Scope, RelativePath, LastWriteTimeUtc, ExpectedAtReferenceTime
```

The generator refuses existing directories, including earlier labs. It supports WhatIf. To repeat the exercise, choose another path, for example C:\RetentionLab02; there is no reset option that deletes existing files.

The new directory contains:

| Item | Purpose |
| --- | --- |
| data/ | Main cleanup scope: 11 files, with four expected candidates |
| boundary-data/ | Three files around the exact retention cutoff; kept separate from deletion exercises |
| reports/ | Output folder outside both scan scopes |
| lab.clixml | Saved policies, reference time and inventory |
| inventory.csv | File paths, actual requested timestamps and expected fixed-time outcomes and main-scope execution results |
| FilePaths.csv | One valid legacy CSV rule targeting data/ |

If you open a new PowerShell session, import the module again and reload the saved lab:

```powershell
$lab = Import-Clixml -LiteralPath 'C:\RetentionLab\lab.clixml'
```

The engine uses last-write time, not creation time. The generator sets LastWriteTimeUtc directly. Its reference time defaults to the current UTC time, rounded down to a whole second. It does not make files large or configure ACL failures, locks, links or network shares; those are separate Windows integration checks. The hidden-file case does exercise a refused deletion under the current implementation.

## Inspect the report and expected results

```powershell
$report = Get-RetentionReport -Policy $lab.Policy -EvaluationTimeUtc $lab.EvaluationTimeUtc
$report | Select-Object Status, CandidateCount, ErrorCount
$report.Candidates | Format-Table Path, LastWriteTimeUtc, Length
$report.Exclusions | Format-Table Path, Kind, Reason

$html = Join-Path $lab.ReportPath 'before-cleanup.html'
Export-RetentionReportHtml -Report $report -LiteralPath $html
Invoke-Item $html
```

Expected status: Completed, four candidates, zero errors. Only these main-scope files qualify:

- old.log: 31 days old with the default 30-day policy.
- older.log: 60 days old.
- nested/old.log: 45 days old, included through recursion.
- .hidden-old.log: 35 days old, with the Windows Hidden attribute set.

Recent, current and future-dated logs stay. old.txt stays because the policy matches only log files. protected/ignore protects the entire protected/ subtree, including its deeper files. The report records that protected directory as one exclusion rather than enumerating its contents. Use Force when listing hidden files in PowerShell:

```powershell
Get-ChildItem -LiteralPath $lab.DataPath -Recurse -Force -File |
    Select-Object FullName, LastWriteTimeUtc, Attributes
```

For the exact boundary check:

```powershell
$boundary = Get-RetentionReport -Policy $lab.BoundaryPolicy -EvaluationTimeUtc $lab.EvaluationTimeUtc
$boundary.Candidates | Select-Object Path, LastWriteTimeUtc
```

Only before-cutoff.log qualifies. exact-cutoff.log and after-cutoff.log do not. Keep the saved EvaluationTimeUtc for this comparison. Invoke-RetentionCleanup always evaluates the current time, so exact-cutoff files will become old enough as time passes. The boundary directory is intentionally outside the main policy.

You can also exercise the existing CSV importer and batch report:

```powershell
$csv = Join-Path $lab.LabPath 'FilePaths.csv'
$import = Import-RetentionPolicyCsv -LiteralPath $csv
$import | Select-Object IsReady, RecordCount
$batch = Get-RetentionBatchReport -LiteralPath $csv -EvaluationTimeUtc $lab.EvaluationTimeUtc
$batch.Reports | Select-Object Status, CandidateCount, ErrorCount
```

The batch should contain one completed report with four candidates.

## Preview, then deliberately delete the synthetic candidates

```powershell
$preview = Invoke-RetentionCleanup -Policy $lab.Policy -Execute -WhatIf
$preview.Actions | Format-Table Path, Status, Reason
```

No files should be removed. After reviewing the paths, execute against the main lab policy only:

```powershell
$execution = Invoke-RetentionCleanup -Policy $lab.Policy -Execute -Confirm
$execution | Select-Object Mode, Status, PlannedCount, DeletedCount, SkippedCount, ErrorCount
$execution.Actions | Format-Table Path, Status, Reason
```

Approve each prompt to exercise all four candidates. The expected result is Completed, PlannedCount=4, DeletedCount=4 and ErrorCount=0. This includes the hidden log. The release candidate fixes its former removal failure while retaining explicit read-only-file protection.

Declining a file deliberately leaves it in place and changes the result accordingly. The recent logs, text file and protected subtree must remain. The boundary fixtures and saved metadata must also remain. inventory.csv and the saved lab Inventory include ExpectedOnExecution values so you can compare every file with its expected outcome.

Run this exercise soon after generating the default lab. Files continue ageing, so long delays or a custom historical EvaluationTimeUtc can change live cleanup results. Use the fixed-time report for reproducible comparisons and a freshly generated default lab for deletion testing.

Save the execution result separately from the pre-cleanup HTML:

```powershell
$receipt = Join-Path $lab.ReportPath 'execution.json'
$execution | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $receipt -Encoding utf8
```

The current HTML exporter accepts report-only scans; it does not render an execution receipt. Regenerate data in a new directory for another run. Reusing the old saved lab after deletion describes the original fixtures, not the remaining files.

## Optional SQL configuration check

The filesystem exercise needs no database. To review SQL access separately, deploy database/sqlserver/001_cleanup_rules.sql into your disposable automation database, then preview a rule pointing at the VM's lab directory:

```powershell
$rule =
@{
    ServerInstance    = 'SQL01'
    Database          = 'AutomationLab'
    JobName           = 'RetentionLab'
    CleanupPath       = $lab.DataPath
    FileExtension     = 'log'
    RetentionDays     = $lab.Policy.RetentionDays
    IncludeSubfolders = $true
}
New-RetentionPolicy @rule -WhatIf
```

Replace the server and database with your lab values. When ready to test the INSERT, run New-RetentionPolicy @rule without WhatIf and inspect its returned RuleId. Get-RetentionJob lists the configured job names. Integrated authentication uses the PowerShell process's Windows account; SQL authentication is available through Credential. The maintained driver is already included in the complete module directory.

SQL-backed execution is now implemented. After creating the lab rule, preview it with Invoke-RetentionCleanup -ServerInstance SQL01 -Database AutomationLab -JobName RetentionLab -Execute -WhatIf. A real Execute run processes its enabled rules and records last-result fields. Creating a database rule still does not schedule or execute it automatically. See [SQL Server configuration](sqlserver-jobs.md).

For the full release acceptance exercise, run tools/Test-SqlServerRelease.ps1 as described in [release readiness](release-readiness.md). It creates its own two-policy lab under a new directory and uses a unique job name.
