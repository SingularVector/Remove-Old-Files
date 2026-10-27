#Requires -Version 7.4
<#
.SYNOPSIS
Runs the release acceptance exercise against a disposable Windows SQL lab.
.DESCRIPTION
Requires an existing dbo.CleanupRules table, a new local lab directory and an
account with SELECT/INSERT/UPDATE access. Creates two synthetic rules under a
unique job name and leaves them and the lab files for inspection. No scheduled
job, database, login or table is created. Execute is required because this test
really deletes the synthetic files it just created.
.EXAMPLE
./tools/Test-SqlServerRelease.ps1 -ServerInstance SQL01 -Database AutomationLab -LiteralPath C:\RetentionRelease01 -Execute
Verifies both preview modes, actual removal, persisted statuses and error reset.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ServerInstance,

    [Parameter(Mandatory)]
    [string]$Database,

    [Parameter(Mandatory)]
    [string]$LiteralPath,

    [pscredential]$Credential,
    [switch]$Execute
)

$ErrorActionPreference = 'Stop'

if (-not $IsWindows)
{
    throw 'Run the SQL release acceptance test in the Windows x64 VM.'
}

if (-not $Execute)
{
    throw 'This acceptance test performs real cleanup of its synthetic files. Pass Execute to run it.'
}

if (-not [IO.Path]::IsPathFullyQualified($LiteralPath) -or (Test-Path -LiteralPath $LiteralPath))
{
    throw 'LiteralPath must be an absolute path for a new disposable lab directory.'
}

Import-Module (Join-Path $PSScriptRoot '../src/RetentionEngine/RetentionEngine.psd1') -Force

$connection =
@{
    ServerInstance = $ServerInstance
    Database       = $Database
    Credential     = $Credential
}

# Verify connectivity and table access before creating any local fixtures.
$null = Get-RetentionJob @connection

$jobName = 'RetentionRelease-' + [guid]::NewGuid().ToString('N')

$generator = Join-Path $PSScriptRoot 'New-RetentionTestData.ps1'

$labs = @(
    (& $generator -LiteralPath (Join-Path $LiteralPath 'first'))
    (& $generator -LiteralPath (Join-Path $LiteralPath 'second'))
)

foreach ($lab in $labs)
{
    $null = New-RetentionPolicy @connection -JobName $jobName -CleanupPath $lab.DataPath -FileExtension log -RetentionDays 30 -IncludeSubfolders
}

function Get-ReleaseRuleStatus
{
    # Acceptance checks deliberately inspect the private adapter; production callers
    # use the public commands. Bind the generated name just like application queries.
    & (Get-Module RetentionEngine) (
        {
            param($Connection, $Name)

            $parameter = [pscustomobject](
                @{
                    Name   = '@JobName'
                    DbType = [Data.DbType]::String
                    Size   = 128
                    Value  = $Name
                }
            )

            $query = 'SELECT RuleId, CleanupPath, LastExecutedAtUtc, LastHadExceptions, LastMachineName FROM dbo.CleanupRules WHERE JobName = @JobName;'
            Invoke-RetentionSqlQuery @Connection -Query $query -Parameters @($parameter)
        }
    ) $connection $jobName
}

$plan = Invoke-RetentionCleanup @connection -JobName $jobName

$preview = Invoke-RetentionCleanup @connection -JobName $jobName -Execute -WhatIf

$before = @(Get-ReleaseRuleStatus)

if ($plan.Status -ne 'Completed' -or $plan.PlannedCount -ne 8 -or
    $preview.Status -ne 'Completed' -or $preview.Mode -ne 'WhatIf' -or
    $preview.DeletedCount -ne 0 -or $before.Count -ne 2 -or
    @($before | Where-Object (
            {
                $null -ne $_.LastExecutedAtUtc -or $null -ne $_.LastHadExceptions -or $null -ne $_.LastMachineName
            }
        )).Count -gt 0)
{
    throw "Preview validation failed for $jobName. Inspect the lab before continuing."
}

# The pre-cleanup HTML remains a report-only snapshot, never an execution receipt.
foreach ($rule in $plan.Rules)
{
    $htmlPath = Join-Path $LiteralPath ($rule.RuleId.ToString() + '-before.html')

    $null = Export-RetentionReportHtml -Report $rule.ExecutionResult.ScanReport -LiteralPath $htmlPath
}

foreach ($lab in $labs)
{
    foreach ($entry in $lab.Inventory)
    {
        if (-not [IO.File]::Exists($entry.Path))
        {
            throw "A preview changed the fixture: $($entry.Path)."
        }
    }
}

$execution = Invoke-RetentionCleanup @connection -JobName $jobName -Execute -Confirm:$false

$after = @(Get-ReleaseRuleStatus)

if ($execution.Status -ne 'Completed' -or $execution.DeletedCount -ne 8 -or
    $execution.ErrorCount -ne 0 -or $after.Count -ne 2 -or
    @($after | Where-Object (
            {
                $null -eq $_.LastExecutedAtUtc -or $_.LastHadExceptions -ne $false -or $_.LastMachineName -ne [Environment]::MachineName
            }
        )).Count -gt 0)
{
    throw "Execution/status validation failed for $jobName. Keep the results for inspection."
}

foreach ($lab in $labs)
{
    foreach ($entry in $lab.Inventory)
    {
        $shouldRemain = $entry.ExpectedOnExecution -ne 'Deleted'

        if ([IO.File]::Exists($entry.Path) -ne $shouldRemain)
        {
            throw "Unexpected post-cleanup file state: $($entry.Path)."
        }
    }
}

# Exercise a genuine filesystem exception, then verify that a later successful
# attempt clears the stored bit rather than leaving an old failure behind.
$readOnly = Join-Path $labs[0].DataPath 'read-only.log'

[IO.File]::WriteAllText($readOnly, 'synthetic read-only acceptance fixture')

[IO.File]::SetLastWriteTimeUtc($readOnly, [datetime]::UtcNow.AddDays(-60))

[IO.File]::SetAttributes($readOnly, [IO.FileAttributes]::ReadOnly)

try
{
    $failure = Invoke-RetentionCleanup @connection -JobName $jobName -Execute -Confirm:$false

    $failedStatus = @(Get-ReleaseRuleStatus | Where-Object CleanupPath -EQ $labs[0].DataPath)

    if ($failure.Status -ne 'Partial' -or $failure.ErrorCount -ne 1 -or
        -not [IO.File]::Exists($readOnly) -or $failedStatus.Count -ne 1 -or -not $failedStatus[0].LastHadExceptions)
    {
        throw "Exception recording failed for $jobName."
    }
}
finally
{
    if ([IO.File]::Exists($readOnly))
    {
        [IO.File]::SetAttributes($readOnly, [IO.FileAttributes]::Normal)
    }
}

$recovery = Invoke-RetentionCleanup @connection -JobName $jobName -Execute -Confirm:$false

$recoveredStatus = @(Get-ReleaseRuleStatus)

if ($recovery.Status -ne 'Completed' -or $recovery.DeletedCount -ne 1 -or $recoveredStatus.Count -ne 2 -or
    @($recoveredStatus | Where-Object (
            {
                $_.LastHadExceptions -ne $false
            }
        )).Count -gt 0)
{
    throw "Exception reset failed for $jobName."
}

[pscustomobject](
    @{
        Status                  = 'Passed'
        JobName                 = $jobName
        LabPath                 = $LiteralPath
        PreviewCandidateCount   = $plan.PlannedCount
        DeletedCount            = $execution.DeletedCount
        ReadOnlyFailureRecorded = $true
        ExceptionFlagCleared    = $true
        Rules                   = $recoveredStatus
    }
)
