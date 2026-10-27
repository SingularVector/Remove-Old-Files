#Requires -Version 7.4
<#
.SYNOPSIS
Creates disposable cleanup fixtures with controlled last-write timestamps.
.DESCRIPTION
Creates a new lab directory only; never overwrites or deletes an existing lab.
Returns policies, a fixed UTC evaluation time and expected results. No database
connection or cleanup is performed. Exact-cutoff fixtures have a separate scope
because actual cleanup always evaluates the current time.
.PARAMETER LiteralPath
Absolute filesystem path for a new lab directory, for example C:\RetentionLab.
.PARAMETER EvaluationTimeUtc
Reference time used to age files. Defaults to the current UTC time.
.PARAMETER RetentionDays
Retention period for both fixture policies. Defaults to 30 days.
.EXAMPLE
$lab = ./examples/New-RetentionTestData.ps1 -LiteralPath C:\RetentionLab
Creates synthetic files, an inventory, saved policies and a legacy CSV example.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$LiteralPath,

    [datetimeoffset]$EvaluationTimeUtc = [datetimeoffset]::UtcNow,

    [ValidateRange(2, 36500)]
    [int]$RetentionDays = 30
)

$ErrorActionPreference = 'Stop'
if (-not [IO.Path]::IsPathFullyQualified($LiteralPath) -or $LiteralPath.Contains('::'))
{
    throw 'LiteralPath must be an absolute filesystem path for a new lab directory.'
}
$root = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($LiteralPath))
if (Test-Path -LiteralPath $root)
{
    throw 'The lab path already exists. Choose a new directory; existing files are never overwritten.'
}
$ancestor = $root
while (-not [string]::IsNullOrEmpty($ancestor))
{
    if (Test-Path -LiteralPath $ancestor)
    {
        $attributes = [IO.File]::GetAttributes($ancestor)
        if ($attributes -band [IO.FileAttributes]::ReparsePoint)
        {
            throw 'The lab path must not pass through a link or reparse point.'
        }
    }
    $ancestor = [IO.Path]::GetDirectoryName($ancestor)
}

# Use whole seconds so exact-cutoff comparisons do not depend on subsecond precision.
$instant = $EvaluationTimeUtc.UtcDateTime
$instant = $instant.AddTicks(-($instant.Ticks % [TimeSpan]::TicksPerSecond))
$cutoff = $instant.AddDays(-$RetentionDays)
$dataPath = Join-Path $root 'data'
$boundaryPath = Join-Path $root 'boundary-data'
$reportPath = Join-Path $root 'reports'
$policy = [pscustomobject](
    @{
        PolicyId      = 'retention-lab'
        RootPath      = $dataPath
        FilePattern   = '*.log'
        RetentionDays = $RetentionDays
        Recurse       = $true
        Enabled       = $true
    }
)
$boundaryPolicy = [pscustomobject](
    @{
        PolicyId      = 'retention-lab-boundary'
        RootPath      = $boundaryPath
        FilePattern   = '*.log'
        RetentionDays = $RetentionDays
        Recurse       = $true
        Enabled       = $true
    }
)

# Scope, name, last-write time, fixed-time scan result, expected main-scope execution result.
$definitions = @(
    @('Main', 'old.log', $instant.AddDays(-($RetentionDays + 1)), 'Candidate', 'Deleted'),
    @('Main', 'older.log', $instant.AddDays(-($RetentionDays + 30)), 'Candidate', 'Deleted'),
    @('Main', 'nested/old.log', $instant.AddDays(-($RetentionDays + 15)), 'Candidate', 'Deleted'),
    @('Main', '.hidden-old.log', $instant.AddDays(-($RetentionDays + 5)), 'Candidate', 'FailedHidden'),
    @('Main', 'recent.log', $instant.AddDays(-1), 'NotOldEnough', 'Kept'),
    @('Main', 'current.log', $instant, 'NotOldEnough', 'Kept'),
    @('Main', 'future.log', $instant.AddDays(1), 'NotOldEnough', 'Kept'),
    @('Main', 'old.txt', $instant.AddDays(-($RetentionDays + 30)), 'PatternMismatch', 'Kept'),
    @('Main', 'protected/ignore', $instant, 'IgnoreMarker', 'Kept'),
    @('Main', 'protected/old.log', $instant.AddDays(-($RetentionDays + 60)), 'IgnoreMarker', 'Kept'),
    @('Main', 'protected/deeper/old.log', $instant.AddDays(-($RetentionDays + 60)), 'IgnoreMarker', 'Kept'),
    @('Boundary', 'before-cutoff.log', $cutoff.AddSeconds(-1), 'Candidate', 'NotRun'),
    @('Boundary', 'exact-cutoff.log', $cutoff, 'NotOldEnough', 'NotRun'),
    @('Boundary', 'after-cutoff.log', $cutoff.AddSeconds(1), 'NotOldEnough', 'NotRun')
)

if (-not $PSCmdlet.ShouldProcess($root, 'Create disposable synthetic cleanup lab'))
{
    return
}

$null = [IO.Directory]::CreateDirectory($root)
foreach ($directory in $dataPath, $boundaryPath, $reportPath)
{
    $null = [IO.Directory]::CreateDirectory($directory)
}
$inventory = foreach ($definition in $definitions)
{
    $scope = switch ($definition[0])
    {
        'Main'
        {
            $dataPath
        }
        'Boundary'
        {
            $boundaryPath
        }
    }
    $relative = $definition[1].Replace('/', [IO.Path]::DirectorySeparatorChar)
    $path = Join-Path $scope $relative
    $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
    [IO.File]::WriteAllText($path, "Synthetic retention fixture. Safe to delete inside this lab only.`n$($definition[1])`n")
    [IO.File]::SetLastWriteTimeUtc($path, $definition[2])
    if ($IsWindows -and $definition[1] -eq '.hidden-old.log')
    {
        $attributes = [IO.File]::GetAttributes($path)
        [IO.File]::SetAttributes($path, $attributes -bor [IO.FileAttributes]::Hidden)
    }
    [pscustomobject](
        @{
            Scope                   = $definition[0]
            RelativePath            = $definition[1]
            Path                    = $path
            LastWriteTimeUtc        = $definition[2].ToString('o')
            ExpectedAtReferenceTime = $definition[3]
            ExpectedOnExecution     = $definition[4]
        }
    )
}

$lab = [pscustomobject](
    @{
        LabPath                        = $root
        DataPath                       = $dataPath
        ReportPath                     = $reportPath
        EvaluationTimeUtc              = $instant.ToString('o')
        CutoffUtc                      = $cutoff.ToString('o')
        Policy                         = $policy
        BoundaryPolicy                 = $boundaryPolicy
        ExpectedMainCandidateCount     = 4
        ExpectedMainDeletedCount       = 3
        ExpectedMainErrorCount         = 1
        ExpectedBoundaryCandidateCount = 1
        Inventory                      = @($inventory)
    }
)
$inventory | Export-Csv -LiteralPath (Join-Path $root 'inventory.csv') -NoTypeInformation -Encoding utf8
$lab | Export-Clixml -LiteralPath (Join-Path $root 'lab.clixml')
[pscustomobject](
    @{
        CleanupPath       = $dataPath
        FileExtension     = 'log'
        AgeTolerance      = $RetentionDays
        IncludeSubFolders = 1
    }
) | Export-Csv -LiteralPath (Join-Path $root 'FilePaths.csv') -NoTypeInformation -Encoding utf8
return $lab
