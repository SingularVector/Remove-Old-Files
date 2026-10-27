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

## What is implemented at this step

Get-RetentionJob, New-RetentionPolicy and the single-table deployment script are implemented. The PostgreSQL prototype and its CI job have been removed. CI now targets Windows; historical non-Windows test evidence does not define product support.

The existing Invoke-RetentionCleanup still takes a policy object. Loading SQL rules by JobName, executing them and writing last-result fields is the next small implementation step. Do not configure a task with an assumed JobName parameter on that command yet. Job discovery has no permission to imply that execution integration already exists.

Local tests mock the connection boundary and use a real in-memory data reader to verify typed/null result mapping, enabled filtering, timeouts, failure propagation, connection-string escaping, authentication selection and resource disposal. Windows-only tests also construct real bundled-provider connections in both authentication modes without opening a network connection. No live SQL Server connection, login, INSERT or table deployment has been tested from the development Mac. Those need Windows and the intended automation database. The database adapter explicitly rejects non-Windows use.
