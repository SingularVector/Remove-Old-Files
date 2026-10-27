function Set-RetentionSqlRuleStatus
{
    param(
        [string]$ServerInstance,
        [string]$Database,
        [string]$JobName,
        [guid]$RuleId,
        [bool]$HadExceptions,
        [pscredential]$Credential
    )

    # Update the original rule only. Never insert a replacement if an SE removed it.
    $query = @'
UPDATE dbo.CleanupRules
SET LastExecutedAtUtc = @ExecutedAtUtc,
    LastHadExceptions = @HadExceptions,
    LastMachineName = @MachineName
OUTPUT INSERTED.RuleId
WHERE RuleId = @RuleId AND JobName = @JobName;
'@

    $parameters = @(

        [pscustomobject](
            @{
                Name   = '@RuleId'
                DbType = [Data.DbType]::Guid
                Size   = 0
                Value  = $RuleId
            }
        )

        [pscustomobject](
            @{
                Name   = '@JobName'
                DbType = [Data.DbType]::String
                Size   = 128
                Value  = $JobName
            }
        )

        [pscustomobject](
            @{
                Name   = '@ExecutedAtUtc'
                DbType = [Data.DbType]::DateTime2
                Size   = 0
                Value  = [datetime]::UtcNow
            }
        )

        [pscustomobject](
            @{
                Name   = '@HadExceptions'
                DbType = [Data.DbType]::Boolean
                Size   = 0
                Value  = $HadExceptions
            }
        )

        [pscustomobject](
            @{
                Name   = '@MachineName'
                DbType = [Data.DbType]::String
                Size   = 128
                Value  = [Environment]::MachineName
            }
        )
    )

    $sqlParameters =
    @{
        ServerInstance = $ServerInstance
        Database       = $Database
        Query          = $query
        Parameters     = $parameters
        Credential     = $Credential
    }

    $updated = @(Invoke-RetentionSqlQuery @sqlParameters)

    if ($updated.Count -ne 1 -or [guid]$updated[0].RuleId -ne $RuleId)
    {
        throw "Status for rule $RuleId was not recorded: the rule was removed or reassigned."
    }
}
