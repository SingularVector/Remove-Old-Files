#Requires -Version 7.4
<#
.SYNOPSIS
Builds a standalone, versioned module directory without installing it globally.
.PARAMETER DestinationPath
Output parent directory. Defaults to artifacts in this repository. An existing
versioned package is never overwritten; choose a new output directory instead.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$DestinationPath = (Join-Path (Split-Path $PSScriptRoot) 'artifacts')
)

$source = Join-Path (Split-Path $PSScriptRoot) 'src/RetentionEngine'
$manifestPath = Join-Path $source 'RetentionEngine.psd1'
$manifest = Test-ModuleManifest -Path $manifestPath -ErrorAction Stop
$data = Import-PowerShellDataFile -LiteralPath $manifestPath
$provider = $null
$drive = $null
$destination = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($DestinationPath, [ref]$provider, [ref]$drive)
if ($provider.Name -ne 'FileSystem')
{
    throw 'DestinationPath must use the filesystem provider.'
}

$packagePath = Join-Path (Join-Path $destination 'RetentionEngine') $manifest.Version.ToString()
$comparison = [StringComparison]::Ordinal
if ($IsWindows -or $IsMacOS)
{
    $comparison = [StringComparison]::OrdinalIgnoreCase
}
if ($packagePath.StartsWith($source + [IO.Path]::DirectorySeparatorChar, $comparison))
{
    throw 'Build output must be outside the module source directory.'
}
if (Test-Path -LiteralPath $packagePath)
{
    throw 'The versioned package already exists. Choose another destination; packages are not overwritten.'
}
if ($data.FileList.Count -eq 0)
{
    throw 'The manifest must explicitly list the module files to package.'
}

foreach ($relativePath in $data.FileList)
{
    if ([IO.Path]::IsPathRooted($relativePath) -or ($relativePath -split '[\\/]') -contains '..')
    {
        throw 'Module FileList must contain relative paths within the module.'
    }
    $file = Get-Item -LiteralPath (Join-Path $source $relativePath) -Force -ErrorAction Stop
    if ($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint))
    {
        throw 'Module FileList must contain regular, nonlinked files.'
    }
}

if ($PSCmdlet.ShouldProcess($packagePath, 'Build standalone retention module package'))
{
    [void][IO.Directory]::CreateDirectory($packagePath)
    foreach ($relativePath in $data.FileList)
    {
        $target = Join-Path $packagePath $relativePath
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
        Copy-Item -LiteralPath (Join-Path $source $relativePath) -Destination $target -ErrorAction Stop
    }
    Copy-Item -LiteralPath (Join-Path (Split-Path $PSScriptRoot) 'LICENSE') -Destination (Join-Path $packagePath 'LICENSE') -ErrorAction Stop
    $builtManifest = Join-Path $packagePath 'RetentionEngine.psd1'
    $null = Test-ModuleManifest -Path $builtManifest -ErrorAction Stop
    [pscustomobject](
        @{
            PackagePath  = $packagePath
            ManifestPath = $builtManifest
            Version      = $manifest.Version.ToString()
        }
    )
}
