function ConvertTo-RetentionPolicy
{
    param([AllowNull()][object]$Policy)

    # Validate and normalise configuration only. Do not access the target filesystem here.
    if ($null -eq $Policy)
    {
        throw [ArgumentException]::new('Policy is required.')
    }

    $values = (
        @{
        }
    )

    foreach ($name in 'PolicyId', 'RootPath', 'FilePattern', 'RetentionDays', 'Recurse', 'Enabled')
    {
        if ($Policy -is [Collections.IDictionary])
        {
            if (-not $Policy.Contains($name))
            {
                throw [ArgumentException]::new("Missing policy field: $name.")
            }

            $values[$name] = $Policy[$name]
        }

        else
        {
            $property = $Policy.PSObject.Properties[$name]

            if ($null -eq $property)
            {
                throw [ArgumentException]::new("Missing policy field: $name.")
            }

            $values[$name] = $property.Value
        }
    }

    foreach ($name in 'PolicyId', 'RootPath', 'FilePattern')
    {
        if ($values[$name] -isnot [string] -or [string]::IsNullOrWhiteSpace($values[$name]))
        {
            throw [ArgumentException]::new("$name must be a nonempty string.")
        }
    }

    foreach ($name in 'Recurse', 'Enabled')
    {
        if ($values[$name] -isnot [bool])
        {
            throw [ArgumentException]::new("$name must be a Boolean, not a string or number.")
        }
    }

    $days = $values.RetentionDays

    if ($days -isnot [byte] -and $days -isnot [sbyte] -and $days -isnot [short] -and

        $days -isnot [ushort] -and $days -isnot [int] -and $days -isnot [uint] -and

        $days -isnot [long] -and $days -isnot [ulong])
    {
        throw [ArgumentException]::new('RetentionDays must be an integer.')
    }

    if ($days -lt 1 -or $days -gt 36500)
    {
        throw [ArgumentException]::new('RetentionDays must be between 1 and 36500.')
    }

    if ($values.FilePattern.IndexOfAny([char[]]'\/[]') -ge 0)
    {
        throw [ArgumentException]::new('FilePattern supports filename literals, * and ? only, without separators or brackets.')
    }

    $root = $values.RootPath

    if (-not [IO.Path]::IsPathFullyQualified($root) -or $root.Contains('::') -or
        ($IsWindows -and ($root.StartsWith('\\?\') -or $root.StartsWith('\\.\') -or $root.Substring(2).Contains(':'))))
    {
        throw [ArgumentException]::new('RootPath must be an absolute filesystem path, not a provider or device path.')
    }

    # Reject parent traversal before lexical normalisation can hide a link ancestor.
    $segments = if ($IsWindows)
    {
        $root -split '[\\/]'
    }
    else
    {
        $root -split '/'
    }

    if ($segments -contains '..')
    {
        throw [ArgumentException]::new('RootPath must not contain parent traversal (..). Supply its explicit absolute path.')
    }

    $root = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($root))

    if ($root -eq [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetPathRoot($root)))
    {
        throw [ArgumentException]::new('Filesystem roots cannot be scanned.')
    }

    return [pscustomobject](
        @{
            PolicyId      = $values.PolicyId
            RootPath      = $root
            FilePattern   = $values.FilePattern
            RetentionDays = [int]$days
            Recurse       = $values.Recurse
            Enabled       = $values.Enabled
        }
    )
}
