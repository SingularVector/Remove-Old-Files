function Invoke-RetentionSqlJob
{
    param(
        [string]$ServerInstance,
        [string]$Database,
        [string]$JobName,
        [pscredential]$Credential,
        [bool]$Execute,
        [bool]$Preview,
        [hashtable]$Confirmation
    )

    $connection =
    @{
        ServerInstance = $ServerInstance
        Database       = $Database
        Credential     = $Credential
    }

    $definition = Get-RetentionSqlJobDefinition @connection -JobName $JobName

    # Detect missing status-write permissions before deleting anything. This read-only
    # check honours column-level grants; it cannot guarantee future DB availability.
    if ($Execute -and -not $Preview -and $definition.Rules.Count -gt 0)
    {
        $permissionQuery = @'
SELECT CASE WHEN
    HAS_PERMS_BY_NAME(N'dbo.CleanupRules', N'OBJECT', N'UPDATE', N'LastExecutedAtUtc', N'COLUMN') = 1 AND
    HAS_PERMS_BY_NAME(N'dbo.CleanupRules', N'OBJECT', N'UPDATE', N'LastHadExceptions', N'COLUMN') = 1 AND
    HAS_PERMS_BY_NAME(N'dbo.CleanupRules', N'OBJECT', N'UPDATE', N'LastMachineName', N'COLUMN') = 1
THEN 1 ELSE 0 END AS CanRecordStatus;
'@

        $permission = @(Invoke-RetentionSqlQuery @connection -Query $permissionQuery)

        if ($permission.Count -ne 1 -or $permission[0].CanRecordStatus -ne 1)
        {
            throw 'The SQL account cannot update the three last-result columns. No cleanup was attempted.'
        }
    }

    $mode = switch ($true)
    {
        {
            $Preview
        }
        {
            'WhatIf'
            break
        }
        {
            $Execute
        }
        {
            'Execute'
            break
        }
        default
        {
            'ReportOnly'
        }
    }

    $results = [Collections.Generic.List[object]]::new()

    $errors = [Collections.Generic.List[object]]::new()

    $job = [pscustomobject](
        @{
            JobName              = $JobName
            Mode                 = $mode
            Status               = 'Completed'
            ExecutionHost        = [Environment]::MachineName
            StartedAtUtc         = [datetime]::UtcNow
            EndedAtUtc           = $null
            ConfiguredRuleCount  = $definition.ConfiguredRuleCount
            EnabledRuleCount     = $definition.Rules.Count
            ProcessedRuleCount   = 0
            UnattemptedRuleCount = $definition.Rules.Count
            PlannedCount         = 0
            DeletedCount         = 0
            SkippedCount         = 0
            ErrorCount           = 0
            Rules                = @()
            Errors               = @()
        }
    )

    foreach ($rule in $definition.Rules)
    {
        $entry = [pscustomobject](
            @{
                RuleId          = $rule.RuleId
                Status          = 'Failed'
                HadExceptions   = $false
                StatusRecorded  = $false
                ExecutionResult = $null
                ErrorMessage    = $null
            }
        )

        try
        {
            # Preserve the caller's confirmation choice and run one fresh scan at a time.
            $cleanup =
            @{
                Policy  = $rule.Policy
                Execute = $Execute
                WhatIf  = $Preview
            }

            foreach ($name in $Confirmation.Keys)
            {
                $cleanup[$name] = $Confirmation[$name]
            }

            $execution = Invoke-RetentionCleanup @cleanup

            $entry.ExecutionResult = $execution

            $entry.Status = $execution.Status

            $entry.HadExceptions = ($execution.ErrorCount -gt 0 -or $execution.ScanReport.ErrorCount -gt 0 -or $execution.Status -in 'Failed', 'Blocked')

            $job.PlannedCount += $execution.PlannedCount

            $job.DeletedCount += $execution.DeletedCount

            $job.SkippedCount += $execution.SkippedCount

            $job.ErrorCount += $execution.ErrorCount + $execution.ScanReport.ErrorCount
        }
        catch
        {
            $entry.HadExceptions = $true

            $entry.ErrorMessage = $_.Exception.Message

            $job.ErrorCount++
        }

        $results.Add($entry)

        $job.ProcessedRuleCount++

        $job.UnattemptedRuleCount--

        if ($Execute -and -not $Preview)
        {
            try
            {
                Set-RetentionSqlRuleStatus @connection -JobName $JobName -RuleId $rule.RuleId -HadExceptions $entry.HadExceptions

                $entry.StatusRecorded = $true
            }
            catch
            {
                $entry.ErrorMessage = $_.Exception.Message

                $job.ErrorCount++

                $errors.Add([pscustomobject](
                        @{
                            RuleId    = $rule.RuleId
                            Operation = 'RecordRuleStatus'
                            Message   = $_.Exception.Message
                        }
                    ))

                # Deletions cannot be rolled back. Do not retry or continue deleting
                # when the database can no longer record the work already attempted.
                break
            }
        }
    }

    $completed = @($results | Where-Object Status -EQ 'Completed').Count

    $failed = @($results | Where-Object Status -In 'Failed', 'Blocked').Count

    $job.Status = switch ($true)
    {
        {
            $definition.Rules.Count -eq 0
        }
        {
            'Disabled'
            break
        }
        {
            $errors.Count -gt 0 -or $failed -gt 0
        }
        {
            if ($job.DeletedCount -gt 0 -or ($completed -gt 0 -and $errors.Count -eq 0))
            {
                'Partial'
            }
            else
            {
                'Failed'
            }

            break
        }
        {
            $completed -ne $definition.Rules.Count
        }
        {
            'Partial'
            break
        }
        default
        {
            'Completed'
        }
    }

    $job.EndedAtUtc = [datetime]::UtcNow

    $job.Rules = $results.ToArray()

    $job.Errors = $errors.ToArray()

    return $job
}
