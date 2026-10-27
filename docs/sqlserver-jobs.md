# Windows cleanup jobs: SQL Server configuration

## Agreed scope

Windows x64, PowerShell 7.4 or later, SQL Server with Windows integrated authentication by default. An optional PSCredential selects SQL Server authentication. One configuration table replaces the CSV as the intended source of cleanup rules. A systems engineer schedules an explicitly named job on the chosen machine. The application does not assign machines, register agents, coordinate threads, claim work or maintain leases.

JobName selects rules. LastMachineName records where a rule actually ran; it is not a routing restriction. Moving a configured task to another server requires no database reassignment. If an SE schedules the same job twice, both runs may execute and the last status update wins. Avoid duplicate scheduling operationally.

## Discover configured job names

No SqlServer PowerShell module or online package installation is required. A private ADO.NET helper uses Microsoft.Data.SqlClient 6.1.7 LTS, bundled with its Windows x64 dependencies under lib/. Copying the complete module directory, including lib/, is sufficient for offline deployment alongside x64 PowerShell; normal network access to SQL Server is still required.

```powershell
Import-Module ./src/RetentionEngine/RetentionEngine.psd1 -Force
Get-RetentionJob -ServerInstance 'SQL01' -Database 'Automation' |
    Select-Object JobName, RuleCount, EnabledRuleCount
```

This returns one object per configured job, ordered by the database's JobName collation. Disabled-only jobs are included so an SE can see all names present in the table. To list only names with active rules:

```powershell
Get-RetentionJob -ServerInstance 'SQL01' -Database 'Automation' -EnabledOnly
```

To retrieve strings for use when configuring a scheduled task:

```powershell
Get-RetentionJob -ServerInstance 'SQL01' -Database 'Automation' |
    Select-Object -ExpandProperty JobName
```

An empty table returns no objects. A connection, authentication or query failure raises an error instead of looking like an empty configuration. Discovery never runs cleanup or changes last-execution fields. Listing a name does not validate its paths or guarantee that its rules can run.

The current Windows identity is used when Credential is omitted. For a SQL login, supply a PSCredential:

```powershell
$sqlCredential = Get-Credential -UserName 'cleanup_reader'
Get-RetentionJob -ServerInstance 'SQL01' -Database 'Automation' -Credential $sqlCredential
```

This prompt is an interactive example. Scheduled tasks should use integrated authentication or obtain their SQL credential through the organisation's existing secret-handling process. The module does not store credentials or create a credential store.

The helper passes the password as a read-only SecureString through SqlCredential; it never embeds it in the connection string. Both modes request encryption and certificate validation, with a 15-second connection timeout and a 30-second query timeout. There is no trust-certificate-bypass parameter. The caller needs SELECT access to dbo.CleanupRules. Server and database settings are escaped by the connection-string builder; the discovery query contains no interpolated caller values. This executes ordinary SQL through ADO.NET, with no SQLCMD preprocessing. Readers, commands and connections are disposed on success and failure, and results are returned only after reading completes.

The deprecated System.Data.SqlClient provider is not used and there is no fallback to it. The bundled Microsoft.Data.SqlClient 6.1 line is [supported through August 2028](https://learn.microsoft.com/en-us/sql/connect/ado-net/sqlclient-driver-support-lifecycle). Version 6.1.7 and its transitive dependencies are pinned in tools/SqlClient/packages.lock.json; lib/BUNDLE.json records the deployed files and hashes. Licences and package metadata travel with the module. Some dependencies support provider features this module does not expose; their inclusion does not add Entra authentication or new product scope.

Only maintainers rebuilding the bundle need a .NET SDK and a populated NuGet cache or approved feed access. Run tools/Update-SqlClientBundle.ps1, review the changed dependency files and licences, then run the tests and package builder. Deployment machines never run a package restore or download code. Validate both authentication modes against the intended Windows SQL Server environment before deployment.

## Create a new cleanup policy

New-RetentionPolicy inserts one rule in dbo.CleanupRules. The configuring account needs INSERT and SELECT permissions on that table. Use discovery separately to list existing jobs. Multiple rules may share one JobName; creating another row is intentional and does not replace an existing rule.

```powershell
$rule =
@{
    ServerInstance    = 'SQL01'
    Database          = 'Automation'
    JobName           = 'AppLogs'
    CleanupPath       = 'D:\Logs'
    FileExtension     = 'log'
    RetentionDays     = 30
    IncludeSubfolders = $true
}
New-RetentionPolicy @rule -WhatIf
New-RetentionPolicy @rule
```

WhatIf validates the inputs without connecting to SQL Server. The actual insert returns the database-generated RuleId and rule values; last-execution fields remain NULL. Use -Disabled to create a disabled rule for review, or -Credential for a SQL login. An explicitly empty FileExtension selects all files. Paths must be absolute Windows directories below a drive or UNC share root; their existence is not checked on the configuring machine. The executing machine remains responsible for scan-time checks. Values are bound as typed SQL parameters, not inserted into SQL text.

This command creates configuration only. It does not schedule a task, scan directories or delete files. An insert failure raises an error. A connection lost after SQL Server commits may leave a saved row even if the caller receives an error; inspect the configured rules before retrying an uncertain write. CSV import remains a local migration/reporting command and does not write to SQL.

## One table in the existing automation database

`database/sqlserver/001_cleanup_rules.sql` creates dbo.CleanupRules. Run it through the normal database deployment process, using an account authorised to create that table. The module never creates databases or tables automatically, and the script refuses to overwrite an existing table.

| Column | Purpose |
| --- | --- |
| RuleId | Unique rule ID generated by SQL Server |
| JobName | Explicit logical job name passed by the configured task |
| CleanupPath | Directory to process |
| FileExtension | Bare extension, or an explicitly documented empty/all-file policy |
| RetentionDays | Integer retention period, 1 through 36500 |
| IncludeSubfolders | Recursion bit |
| Enabled | Whether the rule is active |
| LastExecutedAtUtc | Completion time of the last execution attempt |
| LastHadExceptions | Whether that attempt reported an exception |
| LastMachineName | Machine on which that attempt executed |

The last-result fields are per rule and begin NULL, meaning never executed. Previews will not update them. Detailed outcomes belong in the HTML report and New-LogEntry log. No run-history tables, policy revisions, worker registry or coordination schema are required.

Multiple rows can use the same JobName. Agree on spelling/case conventions with the database owner; grouping follows the database's existing collation. This schema does not create sample jobs or change existing automation data.

## Run a configured job

Invoke-RetentionCleanup accepts either a local Policy or the SQL parameter set below. These are separate parameter sets; do not combine them.

```powershell
$job =
@{
    ServerInstance = 'SQL01'
    Database       = 'Automation'
    JobName        = 'AppLogs'
}

$plan = Invoke-RetentionCleanup @job
$preview = Invoke-RetentionCleanup @job -Execute -WhatIf
$execution = Invoke-RetentionCleanup @job -Execute -Confirm
$execution | Select-Object Mode, Status, ProcessedRuleCount, DeletedCount, ErrorCount
$execution.Rules | Select-Object RuleId, Status, HadExceptions, StatusRecorded, ErrorMessage
```

Loading uses a typed JobName parameter. The complete enabled configuration is validated before any scan or deletion. FileExtension follows the same bare-extension convention as policy creation; an empty extension explicitly selects all files. Equal or nested roots inside one job are rejected, even when their extensions differ. Disabled rows are not scanned or updated. Unknown names raise an error; a known job with no enabled rules returns Disabled.

Rules are read in RuleId order and executed sequentially through the existing single-policy cleanup path. Every rule receives its own fresh scan and eligibility checks. The database read is a configuration snapshot, not a work claim or transaction spanning the filesystem. Stop scheduled tasks before editing their rules. Avoid duplicate scheduling operationally.

## Record the outcome

For a real Execute attempt, the caller needs SELECT and UPDATE permission on LastExecutedAtUtc, LastHadExceptions and LastMachineName. A read-only effective-permissions check runs before the first deletion. Both table-level and appropriate column-level grants are accepted. [HAS_PERMS_BY_NAME](https://learn.microsoft.com/en-us/sql/t-sql/functions/has-perms-by-name-transact-sql) evaluates the current SQL principal's effective permissions; it cannot guarantee future connectivity or permissions.

After each attempted rule, those three fields are updated by its original RuleId and JobName. LastExecutedAtUtc is the client's UTC completion time. LastMachineName is the current execution host, never a routing restriction. LastHadExceptions is true for scan/removal failures and unexpected rule exceptions; a later clean attempt resets it to false. Zero-candidate attempts are still recorded. Declined or changed/protected candidates can make a result Partial without being exceptions, so inspect the detailed results as well as the bit.

Without Execute, or with WhatIf, no status fields change. Disabled and unattempted rules retain their previous status. Configuration errors stop the job before any rule attempt and raise an error; previous last-result fields remain unchanged. Incomplete scans block deletion for their rule and record that failed attempt; independent valid rules can continue.

If status recording fails or its rule was removed/reassigned, the job stops before the next rule. StatusRecorded is false, Errors explains the failure, and UnattemptedRuleCount reports the remaining rules. Prior file deletions cannot be rolled back. There are no automatic retries. A network failure can leave an uncertain SQL write, so inspect the result and table before retrying.

The returned job object contains Rules with each ExecutionResult, plus aggregate counts and timestamps. Save it as JSON for execution evidence. Report-only scans remain exportable as HTML:

```powershell
foreach ($rule in $plan.Rules)
{
    $path = Join-Path 'C:\RetentionReports' ($rule.RuleId.ToString() + '.html')
    Export-RetentionReportHtml -Report $rule.ExecutionResult.ScanReport -LiteralPath $path
}

$execution | ConvertTo-Json -Depth 16 | Set-Content 'C:\RetentionReports\execution.json' -Encoding utf8
```

Create the report directory outside every cleanup root. The HTML exporter is for scan reports, not post-deletion receipts. Execution results retain their explicit mode and actions.

## Schedule the same workflow

Use examples/Invoke-ScheduledRetentionJob.ps1 from the complete repository layout. It imports the bundled module relative to its own location, uses integrated authentication as the task account by default, and suppresses confirmation unless Confirm was explicitly requested. It creates no task and does not install software. Configure Task Scheduler to prevent overlapping instances of the same job. The task account needs SQL and filesystem/network access; validate it using the actual scheduled logon settings, not only an interactive session.

Program: the full path to pwsh.exe. Example arguments:

```text
-NoProfile -File "C:\Remove-Old-Files\examples\Invoke-ScheduledRetentionJob.ps1" -ServerInstance SQL01 -Database Automation -JobName AppLogs -Execute
```

Omit Execute for a read-only plan, or combine Execute and WhatIf for a preview. The entry point writes JSON to stdout and returns process exit 0 for Completed/Disabled, 1 for Partial/Failed/Blocked or a terminating error. Task Scheduler does not retain stdout automatically: capture output/error streams in the SE's existing task wrapper or logging setup. New-LogEntry can consume the structured summary through that wrapper; this module does not import it automatically. Credentials are never written to the result.

## Release verification

The release candidate includes mocked SQL orchestration tests and real disposable-file tests. These verify policy mapping, sequential cleanup, previews, status parameters, exception handling, read-only/hidden files and stop-on-status-failure behaviour. Windows CI for the preceding revision passed, including driver construction; that is not a live SQL test of this new implementation.

Run tools/Test-SqlServerRelease.ps1 in the Windows VM against a disposable automation database to validate the real driver, authentication, INSERT/SELECT/UPDATE, previews, deletion and exception-bit reset together. See [release readiness](release-readiness.md). No live SQL Server connection has been performed from the development Mac.
