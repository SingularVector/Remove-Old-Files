function Test-RetentionExecutionCandidate
{
    param(
        [object]$Candidate,
        [object]$ScanReport
    )

    $root = $ScanReport.NormalizedRoot
    $path = $Candidate.Path
    $comparison = [StringComparison]::Ordinal
    if ($IsWindows)
    {
        $comparison = [StringComparison]::OrdinalIgnoreCase
    }

    if (-not $path.StartsWith($root + [IO.Path]::DirectorySeparatorChar, $comparison))
    {
        throw [IO.IOException]::new('Candidate is outside its policy root.')
    }

    $directory = [IO.Path]::GetDirectoryName($path)
    if (-not $ScanReport.EffectivePolicy.Recurse -and -not $directory.Equals($root, $comparison))
    {
        throw [IO.IOException]::new('Candidate requires recursion, but this policy is nonrecursive.')
    }

    $insideScope = $true
    while ($null -ne $directory)
    {
        $attributes = Get-RetentionAttributes -LiteralPath $directory
        if (($attributes -band [IO.FileAttributes]::ReparsePoint) -or
            -not ($attributes -band [IO.FileAttributes]::Directory))
        {
            throw [IO.IOException]::new('An ancestor is no longer a regular directory.')
        }

        if ($insideScope)
        {
            foreach ($entry in @(Get-RetentionChildren -LiteralPath $directory))
            {
                if ([IO.Path]::GetFileName($entry).Equals('ignore', $comparison))
                {
                    $markerAttributes = Get-RetentionAttributes -LiteralPath $entry
                    if (-not ($markerAttributes -band [IO.FileAttributes]::Directory) -and
                        -not ($markerAttributes -band [IO.FileAttributes]::ReparsePoint))
                    {
                        $marker = Get-RetentionFile -LiteralPath $entry
                        if ($null -ne $marker)
                        {
                            return 'ProtectedByIgnoreMarker'
                        }
                    }
                }
            }
        }

        if ($directory.Equals($root, $comparison))
        {
            $insideScope = $false
        }

        $parent = [IO.Directory]::GetParent($directory)
        $directory = $null
        if ($null -ne $parent)
        {
            $directory = $parent.FullName
        }
    }

    $attributes = Get-RetentionAttributes -LiteralPath $path
    if (($attributes -band [IO.FileAttributes]::ReparsePoint) -or
        ($attributes -band [IO.FileAttributes]::Directory))
    {
        return 'EntryTypeChanged'
    }

    $file = Get-RetentionFile -LiteralPath $path
    if ($null -eq $file)
    {
        return 'NotRegularFile'
    }

    if ($file.Length -ne $Candidate.Length -or $file.LastWriteTimeUtc -ne $Candidate.LastWriteTimeUtc)
    {
        return 'ChangedSinceScan'
    }

    if ($file.LastWriteTimeUtc -ge $ScanReport.CutoffUtc)
    {
        return 'NoLongerEligible'
    }

    return 'Eligible'
}
