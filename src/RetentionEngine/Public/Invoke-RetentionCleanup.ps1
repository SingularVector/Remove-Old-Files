function Invoke-RetentionCleanup
{
    <#
    .SYNOPSIS
    Plans cleanup by default; removes freshly inspected candidates only with Execute.
    .DESCRIPTION
    Accepts one policy, never a saved candidate list. Incomplete scans block execution.
    Rechecks candidate metadata, ancestors and ignore markers before confirmation and
    again immediately before removal. These are not atomic filesystem protections.
    .PARAMETER Policy
    One policy following the same strict contract as Get-RetentionReport.
    .PARAMETER Execute
    Explicitly opts into deletion. Combine with WhatIf to inspect without writing.
    .EXAMPLE
    Invoke-RetentionCleanup -Policy $policy
    Returns a read-only plan without deleting files.
    .EXAMPLE
    Invoke-RetentionCleanup -Policy $policy -Execute -WhatIf
    Previews the operations using PowerShell ShouldProcess without deleting files.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$Policy,

        [switch]$Execute
    )

    $scan = Get-RetentionReport -Policy $Policy
    $actions = [Collections.Generic.List[object]]::new()
    $result = [pscustomobject](
        @{
            RunId = $scan.RunId
            Mode = 'ReportOnly'
            Status = $scan.Status
            ScanReport = $scan
            Actions = @()
            PlannedCount = $scan.CandidateCount
            DeletedCount = 0
            DeletedBytesObserved = [long]0
            SkippedCount = 0
            ErrorCount = 0
        }
    )

    try
    {
        if (-not $Execute)
        {
            foreach ($candidate in $scan.Candidates)
            {
                $actions.Add([pscustomobject](
                        @{
                            Path = $candidate.Path
                            Status = 'Planned'
                            Reason = 'ReportOnly'
                            Message = $null
                        }
                    ))
            }

            return $result
        }

        $result.Mode = 'Execute'
        if ($WhatIfPreference)
        {
            $result.Mode = 'WhatIf'
        }

        # An execution snapshot must not be exported as a no-deletion HTML receipt.
        $scan.Mode = 'PreExecutionSnapshot'
        if ($scan.Status -eq 'Disabled')
        {
            return $result
        }

        if ($scan.Status -ne 'Completed')
        {
            $result.Status = 'Blocked'
            return $result
        }

        foreach ($candidate in $scan.Candidates)
        {
            $action = [pscustomobject](
                @{
                    Path = $candidate.Path
                    Status = 'Skipped'
                    Reason = $null
                    Message = $null
                }
            )
            try
            {
                $eligibility = Test-RetentionExecutionCandidate -Candidate $candidate -ScanReport $scan
                if ($eligibility -ne 'Eligible')
                {
                    $action.Reason = $eligibility
                    $result.SkippedCount++
                    $actions.Add($action)
                    continue
                }

                if (-not $PSCmdlet.ShouldProcess($candidate.Path, 'Permanently remove eligible retention file'))
                {
                    $action.Reason = 'Declined'
                    if ($WhatIfPreference)
                    {
                        $action.Reason = 'WhatIf'
                    }

                    $result.SkippedCount++
                    $actions.Add($action)
                    continue
                }

                # Confirmation may take time. Repeat the checks after it, not just before.
                $eligibility = Test-RetentionExecutionCandidate -Candidate $candidate -ScanReport $scan
                if ($eligibility -ne 'Eligible')
                {
                    $action.Reason = $eligibility
                    $result.SkippedCount++
                    $actions.Add($action)
                    continue
                }

                Remove-RetentionCandidate -LiteralPath $candidate.Path
                $action.Status = 'Deleted'
                $action.Reason = 'RemovalCompleted'
                $result.DeletedCount++
                $result.DeletedBytesObserved += $candidate.Length
            }

            catch
            {
                $action.Status = 'Failed'
                $action.Reason = 'ExecutionError'
                $action.Message = $_.Exception.Message
                $result.ErrorCount++
            }

            $actions.Add($action)
        }

        if ($result.ErrorCount -gt 0)
        {
            $result.Status = 'Partial'
            if ($result.DeletedCount -eq 0)
            {
                $result.Status = 'Failed'
            }
        }

        elseif (@($actions | Where-Object (
                    {
                        $_.Reason -notin @('WhatIf', 'RemovalCompleted')
                    }
                )).Count -gt 0)
        {
            $result.Status = 'Partial'
        }

        return $result
    }

    finally
    {
        $result.Actions = $actions.ToArray()
    }
}
