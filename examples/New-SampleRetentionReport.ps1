#Requires -Version 7.4
<#
.SYNOPSIS
Creates a reproducible HTML illustration from synthetic report data, not a live scan.
.PARAMETER LiteralPath
Existing output directory plus HTML filename. Existing files require -Force.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$LiteralPath,
    [switch]$Force
)
Import-Module (Join-Path $PSScriptRoot '../src/RetentionEngine/RetentionEngine.psd1') -Force
$instant = [datetimeoffset]'2026-10-26T12:00:00Z'
$report = Get-RetentionReport -Policy $null -EvaluationTimeUtc $instant
$report.RunId = 'sample-report-not-a-production-run'
$report.PolicyId = 'sample-automation-logs'
$report.ExecutionHost = 'example-worker'
$report.OriginalRoot = '/example/automation-logs'
$report.NormalizedRoot = '/example/automation-logs'
$report.EffectivePolicy = [pscustomobject]@{
    FilePattern = '*.log'; RetentionDays = 30; Recurse = $true; Enabled = $true
}
$report.CutoffUtc = $instant.UtcDateTime.AddDays(-30)
$report.StartedAtUtc = $instant.UtcDateTime
$report.EndedAtUtc = $instant.UtcDateTime.AddSeconds(2)
$report.Status = 'Partial'
$report.Candidates = @(
    [pscustomobject]@{ Path = '/example/automation-logs/nightly/2026-08.log'; Length = [long]73400320; LastWriteTimeUtc = [datetimeoffset]::Parse('2026-09-01T06:00:00Z').UtcDateTime; Reason = 'LastWriteTimeBeforeCutoff' },
    [pscustomobject]@{ Path = '/example/automation-logs/import/2026-08.log'; Length = [long]12582912; LastWriteTimeUtc = [datetimeoffset]::Parse('2026-09-03T08:30:00Z').UtcDateTime; Reason = 'LastWriteTimeBeforeCutoff' }
)
$report.Exclusions = @(
    [pscustomobject]@{ Path = '/example/automation-logs/protected'; Kind = 'Directory'; Reason = 'IgnoreMarker' },
    [pscustomobject]@{ Path = '/example/automation-logs/current.log'; Kind = 'File'; Reason = 'NotOldEnough' }
)
$report.Errors = @([pscustomobject]@{
    Path = '/example/automation-logs/restricted'; Operation = 'InspectDirectory'; Category = 'DirectoryAccess'
    Message = 'Synthetic example: permission denied. This directory was not inspected.'
})
$report.InspectedFileCount = 3
$report.CandidateCount = 2
$report.CandidateBytes = [long]85983232
$report.ExcludedEntryCount = 2
$report.ExcludedFileCount = 1
$report.ExcludedDirectoryCount = 1
$report.SkippedLinkCount = 0
$report.ErrorCount = 1
Export-RetentionReportHtml -Report $report -LiteralPath $LiteralPath -ReportLabel 'Synthetic demonstration — not a production scan.' -Force:$Force
