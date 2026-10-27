function Import-RetentionSqlClient
{
    # The complete driver bundle travels with the module; deployment never restores packages.
    $driverPath = Join-Path $PSScriptRoot '../lib/Microsoft.Data.SqlClient.dll'
    if (-not [IO.File]::Exists($driverPath))
    {
        throw 'The bundled Microsoft.Data.SqlClient driver is missing. Deploy the complete RetentionEngine package.'
    }

    if ([Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture -ne [Runtime.InteropServices.Architecture]::X64)
    {
        throw 'This driver bundle targets Windows x64. Use an x64 PowerShell process.'
    }

    if (-not ('Microsoft.Data.SqlClient.SqlConnection' -as [type]))
    {
        $null = [Reflection.Assembly]::LoadFrom([IO.Path]::GetFullPath($driverPath))
    }

    $catalog = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../lib/BUNDLE.json') -Raw | ConvertFrom-Json
    $assembly = ('Microsoft.Data.SqlClient.SqlConnection' -as [type]).Assembly
    $version = [Diagnostics.FileVersionInfo]::GetVersionInfo($assembly.Location).ProductVersion.Split('+')[0]
    if ($version -ne $catalog.Version)
    {
        throw "An incompatible SQL client is already loaded ($version). Start a fresh PowerShell process for the bundled driver."
    }
}
