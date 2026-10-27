function Get-RetentionSqlJobDefinition
{
    param(
        [string]$ServerInstance,
        [string]$Database,
        [string]$JobName,
        [pscredential]$Credential
    )

    # Read a deterministic configuration snapshot; no work claiming or machine assignment.
    $query = @'
SELECT RuleId, JobName, CleanupPath, FileExtension, RetentionDays, IncludeSubfolders, Enabled
FROM dbo.CleanupRules
WHERE JobName = @JobName
ORDER BY RuleId;
'@

    $jobParameter = [pscustomobject](
        @{
            Name   = '@JobName'
            DbType = [Data.DbType]::String
            Size   = 128
            Value  = $JobName
        }
    )

    $sqlParameters =
    @{
        ServerInstance = $ServerInstance
        Database       = $Database
        Query          = $query
        Parameters     = @($jobParameter)
        Credential     = $Credential
    }

    $rows = @(Invoke-RetentionSqlQuery @sqlParameters)

    if ($rows.Count -eq 0)
    {
        throw "No configured cleanup job named '$JobName' was found."
    }

    $rules = [Collections.Generic.List[object]]::new()

    $ids = [Collections.Generic.HashSet[guid]]::new()

    # Validate the complete enabled configuration before the first scan or deletion.
    foreach ($row in $rows)
    {
        if ($row.Enabled -isnot [bool])
        {
            throw 'SQL Enabled values must be Boolean.'
        }

        if (-not $row.Enabled)
        {
            continue
        }

        $ruleId = [guid]::Empty

        if (-not [guid]::TryParse([string]$row.RuleId, [ref]$ruleId) -or -not $ids.Add($ruleId))
        {
            throw 'Every enabled SQL rule must have a valid, unique RuleId.'
        }

        if ($row.FileExtension -isnot [string] -or $row.FileExtension.Length -gt 64 -or
            ($row.FileExtension.Length -gt 0 -and $row.FileExtension -notmatch '^[\p{L}\p{N}_-]+(?:\.[\p{L}\p{N}_-]+)*$'))
        {
            throw "Rule $ruleId has an invalid bare FileExtension."
        }

        $pattern = switch ($row.FileExtension)
        {
            ''
            {
                '*'
            }
            default
            {
                '*.' + $row.FileExtension
            }
        }

        $policy = [pscustomobject](
            @{
                PolicyId      = $ruleId.ToString()
                RootPath      = $row.CleanupPath
                FilePattern   = $pattern
                RetentionDays = $row.RetentionDays
                Recurse       = $row.IncludeSubfolders
                Enabled       = $row.Enabled
            }
        )

        $policy = ConvertTo-RetentionPolicy -Policy $policy

        $rules.Add([pscustomobject](
                @{
                    RuleId = $ruleId
                    Policy = $policy
                }
            ))
    }

    # Like CSV batches, reject equal/nested scopes even if their file patterns differ.
    $comparison = [StringComparison]::Ordinal

    if ($IsWindows -or $IsMacOS)
    {
        $comparison = [StringComparison]::OrdinalIgnoreCase
    }

    for ($left = 0; $left -lt $rules.Count; $left++)
    {
        for ($right = $left + 1; $right -lt $rules.Count; $right++)
        {
            $first = $rules[$left].Policy.RootPath

            $second = $rules[$right].Policy.RootPath

            $separator = [IO.Path]::DirectorySeparatorChar

            if ($first.Equals($second, $comparison) -or

                $first.StartsWith($second + $separator, $comparison) -or

                $second.StartsWith($first + $separator, $comparison))
            {
                throw "Job '$JobName' contains overlapping cleanup roots. No rules were run."
            }
        }
    }

    return [pscustomobject](
        @{
            ConfiguredRuleCount = $rows.Count
            Rules               = $rules.ToArray()
        }
    )
}
