function Export-RetentionReportHtml
{
    <#
    .SYNOPSIS
    Exports one report-only retention result as standalone HTML with embedded CSS.
    .DESCRIPTION
    Requires an existing output directory outside the scanned root, without link or
    reparse-point ancestors. Existing reports are protected unless Force is used.
    Writes no scanned files. Contains all supplied candidate, exclusion and error rows.
    .PARAMETER Report
    A report returned by Get-RetentionReport, including unsuccessful scans.
    .PARAMETER LiteralPath
    Explicit .html or .htm destination. Relative paths are resolved from the current
    PowerShell location. Directory parents must already exist.
    .PARAMETER ReportLabel
    Optional context displayed above the outcome, for example a synthetic-data label.
    .PARAMETER Force
    Allows replacing an existing regular report file. Links are always rejected.
    .EXAMPLE
    Export-RetentionReportHtml -Report $report -LiteralPath ./retention-report.html
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][ValidateNotNull()][object]$Report,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$LiteralPath,
        [string]$ReportLabel = '',
        [switch]$Force
    )

    $required = @('RunId', 'PolicyId', 'Mode', 'EngineVersion', 'ExecutionHost', 'OriginalRoot', 'NormalizedRoot',
        'EffectivePolicy', 'AgeBasis', 'EvaluationTimeUtc', 'CutoffUtc', 'StartedAtUtc', 'EndedAtUtc', 'Status',
        'Candidates', 'Exclusions', 'Errors', 'InspectedFileCount', 'CandidateCount', 'CandidateBytes',
        'ExcludedEntryCount', 'ExcludedFileCount', 'ExcludedDirectoryCount', 'SkippedLinkCount', 'ErrorCount', 'DeletedCount')
    foreach ($name in $required)
    {
        if ($null -eq $Report.PSObject.Properties[$name])
        {
            throw [ArgumentException]::new("Report is missing field: $name.")
        }
    }

    if ($Report.Mode -cne 'ReportOnly' -or $Report.DeletedCount -ne 0 -or
        $Report.Status -cnotin @('Completed', 'Partial', 'Failed', 'Disabled'))
    {
        throw [ArgumentException]::new('Expected a report-only result with a recognised status and no deletions.')
    }

    foreach ($entry in @(
            (
                @{
                    Rows       = $Report.Candidates
                    Properties = @('Path', 'Length', 'LastWriteTimeUtc', 'Reason')
                }
            ),
            (
                @{
                    Rows       = $Report.Exclusions
                    Properties = @('Path', 'Kind', 'Reason')
                }
            ),
            (
                @{
                    Rows       = $Report.Errors
                    Properties = @('Path', 'Operation', 'Category', 'Message')
                }
            )
        ))
    {
        foreach ($row in $entry.Rows)
        {
            foreach ($property in $entry.Properties)
            {
                if ($null -eq $row -or $null -eq $row.PSObject.Properties[$property])
                {
                    throw [ArgumentException]::new("Report row is missing field: $property.")
                }
            }
        }
    }

    if (@($Report.Candidates).Count -ne $Report.CandidateCount -or @($Report.Errors).Count -ne $Report.ErrorCount -or
        @($Report.Exclusions).Count -ne $Report.ExcludedEntryCount)
    {
        throw [ArgumentException]::new('Report counts do not agree with the supplied rows.')
    }

    $provider = $null
    $drive = $null
    $destination = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($LiteralPath, [ref]$provider, [ref]$drive)
    if ($provider.Name -ne 'FileSystem')
    {
        throw [ArgumentException]::new('Destination must use the filesystem provider.')
    }

    if ([IO.Path]::GetExtension($destination) -notin @('.html', '.htm'))
    {
        throw [ArgumentException]::new('Destination must have an .html or .htm extension.')
    }

    $segments = if ($IsWindows)
    {
        $LiteralPath -split '[\\/]'
    }
    else
    {
        $LiteralPath -split '/'
    }

    if ($segments -contains '..')
    {
        throw [ArgumentException]::new('Use an explicit destination without parent traversal (..).')
    }

    if ($IsWindows -and ($destination.StartsWith('\\?\') -or $destination.StartsWith('\\.\') -or $destination.Substring(2).Contains(':')))
    {
        throw [ArgumentException]::new('Device and alternate-stream destinations are not supported.')
    }

    $destination = [IO.Path]::GetFullPath($destination)
    # Conservatively compare macOS scope paths without case; common volumes are case-insensitive.
    $comparison = if ($IsWindows -or $IsMacOS)
    {
        [StringComparison]::OrdinalIgnoreCase
    }
    else
    {
        [StringComparison]::Ordinal
    }

    if (-not [string]::IsNullOrEmpty($Report.NormalizedRoot))
    {
        $root = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath([string]$Report.NormalizedRoot))
        $prefix = $root + [IO.Path]::DirectorySeparatorChar
        if ($destination.Equals($root, $comparison) -or $destination.StartsWith($prefix, $comparison))
        {
            throw [ArgumentException]::new('Write reports outside the scanned root.')
        }
    }

    $directory = [IO.Path]::GetDirectoryName($destination)
    $ancestor = $directory
    while ($null -ne $ancestor)
    {
        $attributes = Get-RetentionAttributes -LiteralPath $ancestor
        if (($attributes -band [IO.FileAttributes]::ReparsePoint) -or -not ($attributes -band [IO.FileAttributes]::Directory))
        {
            throw [IO.IOException]::new('Output directory and ancestors must be existing directories without links/reparse points.')
        }

        $parent = [IO.Directory]::GetParent($ancestor)
        $ancestor = if ($null -eq $parent)
        {
            $null
        }
        else
        {
            $parent.FullName
        }
    }

    # GetAttributes distinguishes missing files from inaccessible entries and dangling links.
    $existing = $null
    try
    {
        $existing = Get-RetentionAttributes -LiteralPath $destination
    }

    catch
    {
        $exception = $_.Exception
        while ($null -ne $exception.InnerException)
        {
            $exception = $exception.InnerException
        }

        if ($exception -isnot [IO.FileNotFoundException])
        {
            throw
        }
    }

    if ($null -ne $existing)
    {
        if (($existing -band [IO.FileAttributes]::ReparsePoint) -or ($existing -band [IO.FileAttributes]::Directory))
        {
            throw [IO.IOException]::new('Output must not be a link, reparse point or directory.')
        }

        if (-not $IsWindows)
        {
            $item = Get-Item -LiteralPath $destination -Force -ErrorAction Stop
            if ($item.UnixStat.ItemType.ToString() -ne 'File')
            {
                throw [IO.IOException]::new('Output must be a regular file.')
            }
        }

        if (-not $Force)
        {
            throw [IO.IOException]::new('Output already exists. Use -Force to replace a regular report file.')
        }
    }

    $statusText = switch -CaseSensitive ($Report.Status)
    {
        'Completed'
        {
            'Inspection completed. Candidates reflect the policy at scan time.'
        }

        'Partial'
        {
            'INCOMPLETE INSPECTION: some paths could not be checked. Candidate totals are incomplete.'
        }

        'Failed'
        {
            'INSPECTION FAILED: this is not a successful empty scan. Review the errors below.'
        }

        'Disabled'
        {
            'POLICY DISABLED: the root was not inspected. Zero candidates does not mean no old files exist.'
        }
    }

    $policyRows = [Collections.Generic.List[object]]::new()
    foreach ($pair in @(
            @('Policy', $Report.PolicyId), @('Original root', $Report.OriginalRoot), @('Scanned root', $Report.NormalizedRoot),
            @('Age basis', $Report.AgeBasis), @('Evaluation time', $Report.EvaluationTimeUtc), @('Cutoff (strictly older)', $Report.CutoffUtc),
            @('Started', $Report.StartedAtUtc), @('Finished', $Report.EndedAtUtc), @('Execution host', $Report.ExecutionHost),
            @('Engine version', $Report.EngineVersion), @('Run identifier', $Report.RunId)
        ))
    {
        $policyRows.Add([pscustomobject](
                @{
                    Setting = $pair[0]
                    Value   = $pair[1]
                }
            ))
    }

    if ($null -ne $Report.EffectivePolicy)
    {
        foreach ($name in 'FilePattern', 'RetentionDays', 'Recurse', 'Enabled')
        {
            $policyRows.Add([pscustomobject](
                    @{
                        Setting = $name
                        Value   = $Report.EffectivePolicy.$name
                    }
                ))
        }
    }

    $policyHtml = ConvertTo-RetentionHtmlTable -Rows $policyRows.ToArray() -Properties Setting, Value -Labels Setting, Value -EmptyText 'Policy unavailable.'
    $candidateHtml = ConvertTo-RetentionHtmlTable -Rows @($Report.Candidates) -Properties Path, Length, LastWriteTimeUtc, Reason -Labels 'File path', 'Bytes', 'Last write (UTC)', 'Selection reason' -EmptyText 'No candidate records. Check the run status before interpreting this as an empty successful scan.'
    $exclusionHtml = ConvertTo-RetentionHtmlTable -Rows @($Report.Exclusions) -Properties Path, Kind, Reason -Labels Path, Kind, Reason -EmptyText 'No exclusions recorded.'
    $errorHtml = ConvertTo-RetentionHtmlTable -Rows @($Report.Errors) -Properties Path, Operation, Category, Message -Labels Path, Operation, Category, Message -EmptyText 'No errors recorded.'
    $byteValue = [long]$Report.CandidateBytes
    $space = switch ($true)
    {
        {
            $byteValue -ge 1GB
        }
        {
            '{0:0.##} GiB' -f ($byteValue / 1GB)
            break
        }
        {
            $byteValue -ge 1MB
        }
        {
            '{0:0.##} MiB' -f ($byteValue / 1MB)
            break
        }
        {
            $byteValue -ge 1KB
        }
        {
            '{0:0.##} KiB' -f ($byteValue / 1KB)
            break
        }
        default
        {
            "$byteValue B"
        }
    }

    $labelHtml = if ([string]::IsNullOrWhiteSpace($ReportLabel))
    {
        ''
    }

    else
    {
        '<p class="report-label">' + (ConvertTo-RetentionHtmlText $ReportLabel) + '</p>'
    }

    $cards = [Text.StringBuilder]::new()
    foreach ($pair in @(
            @('Candidate files', $Report.CandidateCount), @('Potential space reclaimable', $space),
            @('Inspected regular files', $Report.InspectedFileCount), @('Observed exclusions', $Report.ExcludedEntryCount), @('Errors', $Report.ErrorCount)
        ))
    {
        [void]$cards.Append('<div class="card"><span>').Append((ConvertTo-RetentionHtmlText $pair[0])).Append('</span><strong>').Append((ConvertTo-RetentionHtmlText $pair[1])).Append('</strong></div>')
    }

    $status = ConvertTo-RetentionHtmlText $Report.Status
    $html = @"
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
<title>Retention report — $status</title>
<style>
:root
{
    color-scheme:light;
    --ink:#172033;
    --muted:#4b596d;
    --line:#d8e1eb;
    --teal:#0c665c
}
*
{
    box-sizing:border-box
}
body
{
    margin:0;
    background:#f3f6fa;
    color:var(--ink);
    font:16px/1.6 system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif
}
main
{
    max-width:1200px;
    margin:auto;
    padding:42px 28px 64px
}
.eyebrow
{
    font-size:.8rem;
    letter-spacing:.14em;
    color:var(--teal);
    font-weight:750;
    text-transform:uppercase
}
h1
{
    font-size:clamp(2rem,5vw,3.3rem);
    line-height:1.12;
    letter-spacing:-.035em;
    margin:12px 0 20px
}
h2
{
    margin:0 0 14px;
    font-size:1.35rem
}
.notice
{
    padding:20px 24px;
    border:1px solid var(--line);
    border-left:6px solid var(--teal);
    border-radius:12px;
    background:#fff
}
.notice h2
{
    margin:0 0 5px
}
.notice p
{
    margin:5px 0
}
.status-Partial
{
    border-left-color:#a15b00;
    background:#fff8e8
}
.status-Failed
{
    border-left-color:#b42318;
    background:#fff1f0
}
.status-Disabled
{
    border-left-color:#586477;
    background:#edf1f6
}
.mode
{
    font-weight:750
}
.report-label
{
    padding:10px 14px;
    background:#e4edf3;
    border-radius:8px;
    font-weight:650
}
.cards
{
    display:grid;
    grid-template-columns:repeat(auto-fit,minmax(170px,1fr));
    gap:12px;
    margin:24px 0
}
.card
{
    background:#fff;
    border:1px solid var(--line);
    border-radius:12px;
    padding:18px
}
.card span
{
    display:block;
    font-size:.85rem;
    color:var(--muted)
}
.card strong
{
    display:block;
    font-size:1.75rem;
    overflow-wrap:anywhere;
    margin-top:6px
}
section
{
    background:#fff;
    border:1px solid var(--line);
    border-radius:14px;
    padding:24px;
    margin-top:20px
}
.table-wrap
{
    overflow-x:auto
}
table
{
    width:100%;
    border-collapse:collapse;
    font-size:.9rem;
    table-layout:fixed
}
th,td
{
    padding:12px 14px;
    text-align:left;
    vertical-align:top;
    border-bottom:1px solid var(--line);
    overflow-wrap:anywhere
}
th
{
    background:#edf3f7;
    font-weight:700
}
tbody tr:last-child td
{
    border-bottom:0
}
p
{
    overflow-wrap:anywhere
}
.caption,.empty,footer
{
    color:var(--muted);
    font-size:.9rem
}
footer
{
    margin-top:28px
}
@media(max-width:600px)
{
    main
    {
        padding:24px 14px
    }
    section
    {
        padding:16px
    }
    th,td
    {
        padding:9px 7px;
        font-size:.8rem
    }
    .cards
    {
        grid-template-columns:repeat(2,minmax(0,1fr))
    }
}
@media print
{
    body
    {
        background:#fff
    }
    main
    {
        padding:0;
        max-width:none
    }
    .cards
    {
        grid-template-columns:repeat(5,1fr)
    }
    section,.card,.notice
    {
        break-inside:avoid;
        border-radius:0
    }
    thead
    {
        display:table-header-group
    }
    tr
    {
        break-inside:avoid
    }
    section
    {
        break-inside:auto
    }
    th,td
    {
        font-size:9pt
    }
    footer
    {
        font-size:9pt
    }
}
</style>
</head>
<body><main>
$labelHtml
<header><p class="eyebrow">Remove-OldFiles · Retention engine</p><h1>Inspect first.<br>Decide with evidence.</h1></header>
<div class="notice status-$status" role="status"><h2>$status</h2><p>$(ConvertTo-RetentionHtmlText $statusText)</p><p class="mode">Report only — no files deleted.</p></div>
<div class="cards">$($cards.ToString())</div>
<p class="caption">$(ConvertTo-RetentionHtmlText $Report.CandidateBytes) candidate bytes across observed files, not guaranteed recoverable disk space. Protected subtrees are not counted. This report is a scan-time snapshot, not deletion authorisation.</p>
<section aria-labelledby="policy-heading"><h2 id="policy-heading">Policy &amp; scope</h2>$policyHtml</section>
<section aria-labelledby="errors-heading"><h2 id="errors-heading">Errors requiring attention</h2>$errorHtml</section>
<section aria-labelledby="candidates-heading"><h2 id="candidates-heading">Candidate files</h2>$candidateHtml</section>
<section aria-labelledby="excluded-heading"><h2 id="excluded-heading">Observed exclusions</h2><p class="caption">Entries actually observed; no estimate is made for unseen descendants.</p>$exclusionHtml</section>
<footer>Standalone report · All timestamps shown in UTC · Review paths and diagnostics before sharing this file.</footer>
</main></body></html>
"@
    if ($PSCmdlet.ShouldProcess($destination, 'Write standalone retention HTML report'))
    {
        Write-RetentionHtmlFile -Destination $destination -Content $html -Overwrite $Force.IsPresent
        [pscustomobject](
            @{
                Path   = $destination
                RunId  = $Report.RunId
                Status = $Report.Status
            }
        )
    }
}
