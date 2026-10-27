function Get-RetentionReport
{
    <#
    .SYNOPSIS
    Reports files eligible under one retention policy without changing files.
    .DESCRIPTION
    Uses LastWriteTimeUtc strictly earlier than the cutoff. An ignore file protects
    its entire subtree. Links and reparse points are not followed. This is a scan,
    not a transactional snapshot or an authorisation to delete its results later.
    .PARAMETER Policy
    Object or dictionary containing PolicyId, RootPath, FilePattern, RetentionDays,
    Recurse and Enabled. Boolean and integer fields must have their actual types.
    .PARAMETER EvaluationTimeUtc
    Fixed evaluation instant for reproducible scans. Defaults to the current UTC time.
    .EXAMPLE
    Get-RetentionReport -Policy $policy
    Returns one run object. Inspect Status and Errors as well as Candidates.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()][object]$Policy,
        [datetimeoffset]$EvaluationTimeUtc = [datetimeoffset]::UtcNow
    )

    $candidates = [Collections.Generic.List[object]]::new()
    $exclusions = [Collections.Generic.List[object]]::new()
    $errors = [Collections.Generic.List[object]]::new()
    $report = [pscustomobject](
        @{
            RunId                  = [guid]::NewGuid().ToString()
            PolicyId               = $null
            Mode                   = 'ReportOnly'
            EngineVersion          = '2.0.0-rc1'
            ExecutionHost          = [Environment]::MachineName
            OriginalRoot           = $null
            NormalizedRoot         = $null
            EffectivePolicy        = $null
            AgeBasis               = 'LastWriteTimeUtc'
            EvaluationTimeUtc      = $EvaluationTimeUtc.UtcDateTime
            CutoffUtc              = $null
            StartedAtUtc           = [datetime]::UtcNow
            EndedAtUtc             = $null
            Status                 = 'Failed'
            Candidates             = @()
            Exclusions             = @()
            Errors                 = @()
            InspectedFileCount     = 0
            CandidateCount         = 0
            CandidateBytes         = [long]0
            ExcludedEntryCount     = 0
            ExcludedFileCount      = 0
            ExcludedDirectoryCount = 0
            SkippedLinkCount       = 0
            ErrorCount             = 0
            DeletedCount           = 0
        }
    )

    try
    {
        try
        {
            # Retain caller context in validation errors, even when normalisation fails.
            switch ($Policy)
            {
                {
                    $_ -is [Collections.IDictionary]
                }
                {
                    $report.PolicyId = $Policy['PolicyId']
                    $report.OriginalRoot = $Policy['RootPath']
                    break
                }
                {
                    $null -ne $_
                }
                {
                    foreach ($name in 'PolicyId', 'RootPath')
                    {
                        $property = $Policy.PSObject.Properties[$name]

                        if ($null -ne $property)
                        {
                            $target = switch ($name)
                            {
                                'PolicyId'
                                {
                                    'PolicyId'
                                }
                                'RootPath'
                                {
                                    'OriginalRoot'
                                }
                            }

                            $report.$target = $property.Value
                        }
                    }
                }
            }

            $values = ConvertTo-RetentionPolicy -Policy $Policy
            $root = $values.RootPath
            $report.NormalizedRoot = $root
            $report.CutoffUtc = $report.EvaluationTimeUtc.AddDays(-$values.RetentionDays)
            $report.EffectivePolicy = $values
        }

        catch
        {
            $errors.Add([pscustomobject](
                    @{
                        Path      = $report.OriginalRoot
                        Operation = 'ValidatePolicy'
                        Category  = 'Validation'
                        Message   = $_.Exception.Message
                    }
                ))
            return $report
        }

        if (-not $values.Enabled)
        {
            $report.Status = 'Disabled'
            return $report
        }

        # Check every ancestor without resolving links into a different apparent root.
        $ancestor = $root
        try
        {
            while ($null -ne $ancestor)
            {
                $attributes = Get-RetentionAttributes -LiteralPath $ancestor
                if ($attributes -band [IO.FileAttributes]::ReparsePoint)
                {
                    throw [IO.IOException]::new('Root and its ancestors must not be links or reparse points.')
                }

                if (-not ($attributes -band [IO.FileAttributes]::Directory))
                {
                    throw [IO.IOException]::new('Root and its ancestors must be directories.')
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
        }

        catch
        {
            $errors.Add([pscustomobject](
                    @{
                        Path      = $ancestor
                        Operation = 'ValidateRoot'
                        Category  = 'RootAccess'
                        Message   = $_.Exception.Message
                    }
                ))
            return $report
        }

        $comparison = if ($IsWindows)
        {
            [StringComparison]::OrdinalIgnoreCase
        }
        else
        {
            [StringComparison]::Ordinal
        }

        $options = [Text.RegularExpressions.RegexOptions]::CultureInvariant
        if ($IsWindows)
        {
            $options = $options -bor [Text.RegularExpressions.RegexOptions]::IgnoreCase
        }

        $pattern = '\A' + [regex]::Escape($values.FilePattern).Replace('\*', '.*').Replace('\?', '.') + '\z'
        $matcher = [regex]::new($pattern, $options -bor [Text.RegularExpressions.RegexOptions]::Singleline)
        $pending = [Collections.Generic.Stack[string]]::new()
        $pending.Push($root)
        $report.Status = 'Completed'
        while ($pending.Count -gt 0)
        {
            $directory = $pending.Pop()
            try
            {
                # Recheck directories immediately before visiting them.
                $attributes = Get-RetentionAttributes -LiteralPath $directory
                if (($attributes -band [IO.FileAttributes]::ReparsePoint) -or
                    -not ($attributes -band [IO.FileAttributes]::Directory))
                {
                    throw [IO.IOException]::new('Directory changed type before enumeration.')
                }

                $children = @(Get-RetentionChildren -LiteralPath $directory)
                $protected = $false
                foreach ($child in $children)
                {
                    if ([IO.Path]::GetFileName($child).Equals('ignore', $comparison))
                    {
                        $markerAttributes = Get-RetentionAttributes -LiteralPath $child
                        if (-not ($markerAttributes -band [IO.FileAttributes]::ReparsePoint) -and
                            -not ($markerAttributes -band [IO.FileAttributes]::Directory))
                        {
                            $marker = Get-RetentionFile -LiteralPath $child
                            if ($null -ne $marker)
                            {
                                $protected = $true
                                break
                            }
                        }
                    }
                }
            }

            catch
            {
                $errors.Add([pscustomobject](
                        @{
                            Path      = $directory
                            Operation = 'InspectDirectory'
                            Category  = 'DirectoryAccess'
                            Message   = $_.Exception.Message
                        }
                    ))
                $report.Status = if ($directory -eq $root)
                {
                    'Failed'
                }
                else
                {
                    'Partial'
                }

                continue
            }

            if ($protected)
            {
                $exclusions.Add([pscustomobject](
                        @{
                            Path   = $directory
                            Kind   = 'Directory'
                            Reason = 'IgnoreMarker'
                        }
                    ))
                continue
            }

            foreach ($child in $children)
            {
                try
                {
                    $attributes = Get-RetentionAttributes -LiteralPath $child
                    switch ($true)
                    {
                        {
                            $attributes -band [IO.FileAttributes]::ReparsePoint
                        }
                        {
                            $exclusions.Add([pscustomobject](
                                    @{
                                        Path   = $child
                                        Kind   = 'Link'
                                        Reason = 'LinkOrReparsePoint'
                                    }
                                ))

                            break
                        }
                        {
                            $attributes -band [IO.FileAttributes]::Directory
                        }
                        {
                            if ($values.Recurse)
                            {
                                $pending.Push($child)
                            }

                            else
                            {
                                $exclusions.Add([pscustomobject](
                                        @{
                                            Path   = $child
                                            Kind   = 'Directory'
                                            Reason = 'RecursionDisabled'
                                        }
                                    ))
                            }

                            break
                        }
                        default
                        {
                            $file = Get-RetentionFile -LiteralPath $child
                            if ($null -eq $file)
                            {
                                $exclusions.Add([pscustomobject](
                                        @{
                                            Path   = $child
                                            Kind   = 'Other'
                                            Reason = 'NotRegularFile'
                                        }
                                    ))
                                continue
                            }

                            $report.InspectedFileCount++
                            switch ($true)
                            {
                                {
                                    -not $matcher.IsMatch([IO.Path]::GetFileName($child))
                                }
                                {
                                    $exclusions.Add([pscustomobject](
                                            @{
                                                Path   = $child
                                                Kind   = 'File'
                                                Reason = 'PatternMismatch'
                                            }
                                        ))

                                    break
                                }
                                {
                                    $file.LastWriteTimeUtc -ge $report.CutoffUtc
                                }
                                {
                                    $exclusions.Add([pscustomobject](
                                            @{
                                                Path   = $child
                                                Kind   = 'File'
                                                Reason = 'NotOldEnough'
                                            }
                                        ))

                                    break
                                }
                                default
                                {
                                    $candidates.Add([pscustomobject](
                                            @{
                                                Path             = $child
                                                Length           = $file.Length
                                                LastWriteTimeUtc = $file.LastWriteTimeUtc
                                                Reason           = 'LastWriteTimeBeforeCutoff'
                                            }
                                        ))
                                    $report.CandidateBytes += $file.Length

                                }
                            }

                        }
                    }
                }

                catch
                {
                    $errors.Add([pscustomobject](
                            @{
                                Path      = $child
                                Operation = 'InspectEntry'
                                Category  = 'EntryAccess'
                                Message   = $_.Exception.Message
                            }
                        ))
                    $report.Status = 'Partial'
                }
            }
        }

        return $report
    }

    finally
    {
        $report.Candidates = @($candidates | Sort-Object -Property Path, Reason -CaseSensitive)
        $report.Exclusions = @($exclusions | Sort-Object -Property Path, Reason -CaseSensitive)
        $report.Errors = @($errors | Sort-Object -Property Path, Operation -CaseSensitive)
        $report.CandidateCount = $candidates.Count
        $report.ExcludedEntryCount = $exclusions.Count
        $report.ExcludedFileCount = @($exclusions | Where-Object Kind -EQ 'File').Count
        $report.ExcludedDirectoryCount = @($exclusions | Where-Object Kind -EQ 'Directory').Count
        $report.SkippedLinkCount = @($exclusions | Where-Object Kind -EQ 'Link').Count
        $report.ErrorCount = $errors.Count
        $report.EndedAtUtc = [datetime]::UtcNow
    }
}
