function Get-RetentionBatchReport
{
    <#
    .SYNOPSIS
    Validates the entire legacy CSV before scanning any policy, then reports each.
    .DESCRIPTION
    Invalid rows, malformed files and overlapping roots block the entire batch.
    Runtime scan failures retain other reports and make the batch Partial or Failed.
    No files are deleted. Export individual Reports with Export-RetentionReportHtml.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$LiteralPath,
        [datetimeoffset]$EvaluationTimeUtc = [datetimeoffset]::UtcNow
    )
    $import = Import-RetentionPolicyCsv -LiteralPath $LiteralPath
    $reports = [Collections.Generic.List[object]]::new()
    $status = 'Failed'
    if ($import.IsReady)
    {
        foreach ($policy in $import.Policies)
        {
            $reports.Add((Get-RetentionReport -Policy $policy -EvaluationTimeUtc $EvaluationTimeUtc))
        }

        $successful = @($reports | Where-Object Status -EQ 'Completed').Count
        $partial = @($reports | Where-Object Status -EQ 'Partial').Count
        $status = switch ($true)
        {
            {
                $successful -eq $reports.Count
            }
            {
                'Completed'
                break
            }
            {
                $successful -gt 0 -or $partial -gt 0
            }
            {
                'Partial'
                break
            }
            default
            {
                'Failed'
            }
        }
    }

    [pscustomobject](
        @{
            Status            = $status
            Mode              = 'ReportOnly'
            EvaluationTimeUtc = $EvaluationTimeUtc.UtcDateTime
            Import            = $import
            Reports           = $reports.ToArray()
            PolicyCount       = $import.Policies.Count
            ReportCount       = $reports.Count
            DeletedCount      = 0
        }
    )
}
