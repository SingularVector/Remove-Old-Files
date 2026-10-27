#Requires -Version 7.4
<#
.SYNOPSIS
Rebuilds the pinned Windows x64 SQL client bundle on a development machine.
.DESCRIPTION
Requires a .NET SDK supporting net8.0 and a populated NuGet cache or package-feed
access. Deployment machines do not run this tool. Review the lock file, notices,
checksums and manifest changes together before committing a dependency update.
#>
[CmdletBinding()]
param(
    [string]$DotnetPath = 'dotnet'
)

$ErrorActionPreference = 'Stop'
$repository = Split-Path $PSScriptRoot
$projectDirectory = Join-Path $PSScriptRoot 'SqlClient'
$moduleDirectory = Join-Path $repository 'src/RetentionEngine'
$bundleDirectory = Join-Path $moduleDirectory 'lib'
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('retention-sqlclient-' + [guid]::NewGuid())
try
{
    $project = Join-Path $projectDirectory 'SqlClient.Bundle.csproj'
    & $DotnetPath publish $project --configuration Release --output $temporary --self-contained false -p:RestoreLockedMode=true --nologo
    if ($LASTEXITCODE -ne 0)
    {
        throw 'SQL client restore/publish failed; the existing bundle was not changed.'
    }
    if (-not [IO.File]::Exists((Join-Path $temporary 'Microsoft.Data.SqlClient.dll')))
    {
        throw 'The expected SQL client was not published; the existing bundle was not changed.'
    }

    $assets = Get-Content (Join-Path $projectDirectory 'obj/project.assets.json') -Raw | ConvertFrom-Json -AsHashtable
    $notices = Join-Path $temporary 'licenses'
    foreach ($entry in $assets.libraries.GetEnumerator())
    {
        if ($entry.Value.type -ne 'package')
        {
            continue
        }
        $packagePath = $null
        foreach ($packageRoot in $assets.packageFolders.Keys)
        {
            $candidate = Join-Path $packageRoot $entry.Value.path
            if ([IO.Directory]::Exists($candidate))
            {
                $packagePath = $candidate
                break
            }
        }
        if ($null -eq $packagePath)
        {
            throw "The restored package was not found: $($entry.Key)."
        }
        foreach ($file in Get-ChildItem -LiteralPath $packagePath -Recurse -File)
        {
            if ($file.Extension -eq '.nuspec' -or $file.Name -match 'license|thirdparty|notice')
            {
                $relative = [IO.Path]::GetRelativePath($packagePath, $file.FullName)
                $packageName = $entry.Key.ToLowerInvariant().Replace('/', '.')
                $target = Join-Path (Join-Path $notices $packageName) $relative
                $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
                Copy-Item -LiteralPath $file.FullName -Destination $target
            }
        }
    }
    Copy-Item (Join-Path $projectDirectory 'LICENSE-MIT.txt') (Join-Path $temporary 'LICENSE-MIT.txt')
    foreach ($file in Get-ChildItem -LiteralPath $temporary -File)
    {
        if ($file.Name -like 'SqlClient.Bundle.*')
        {
            Remove-Item -LiteralPath $file.FullName
        }
    }
    $hashes = [Collections.Specialized.OrderedDictionary]::new()
    foreach ($file in Get-ChildItem -LiteralPath $temporary -Recurse -File | Sort-Object FullName)
    {
        $relative = [IO.Path]::GetRelativePath($temporary, $file.FullName).Replace('\', '/')
        $hashes[$relative] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    }
    $projectData = [xml](Get-Content -LiteralPath $project -Raw)
    $catalog = [pscustomobject](
        @{
            Driver          = 'Microsoft.Data.SqlClient'
            Version         = $projectData.Project.ItemGroup.PackageReference.Version
            Runtime         = 'win-x64'
            TargetFramework = 'net8.0'
            Files           = $hashes
        }
    )
    $catalog | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $temporary 'BUNDLE.json') -Encoding utf8

    # Replace generated dependencies only after restore and notice collection succeed.
    $null = [IO.Directory]::CreateDirectory($bundleDirectory)
    $relativeFiles = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($file in Get-ChildItem -LiteralPath $temporary -Recurse -File)
    {
        $relative = [IO.Path]::GetRelativePath($temporary, $file.FullName)
        $null = $relativeFiles.Add($relative)
        $target = Join-Path $bundleDirectory $relative
        $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
        Copy-Item -LiteralPath $file.FullName -Destination $target -Force
    }
    foreach ($file in Get-ChildItem -LiteralPath $bundleDirectory -Recurse -File)
    {
        $relative = [IO.Path]::GetRelativePath($bundleDirectory, $file.FullName)
        if (-not $relativeFiles.Contains($relative))
        {
            Remove-Item -LiteralPath $file.FullName -Force
        }
    }
    $lines = foreach ($file in Get-ChildItem -LiteralPath $bundleDirectory -Recurse -File | Sort-Object FullName)
    {
        $relative = [IO.Path]::GetRelativePath($moduleDirectory, $file.FullName).Replace('\', '/')
        "        '$relative'"
    }
    $manifestPath = Join-Path $moduleDirectory 'RetentionEngine.psd1'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw
    $replacement = "        # SQL CLIENT BUNDLE START`n" + ($lines -join "`n") + "`n        # SQL CLIENT BUNDLE END"
    $manifest = [regex]::Replace($manifest, '(?ms)^        # SQL CLIENT BUNDLE START.*?^        # SQL CLIENT BUNDLE END', $replacement)
    [IO.File]::WriteAllText($manifestPath, $manifest)
}
finally
{
    if ([IO.Directory]::Exists($temporary))
    {
        Remove-Item -LiteralPath $temporary -Recurse -Force
    }
}
