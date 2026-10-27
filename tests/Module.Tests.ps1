BeforeAll (
    {
        $script:repositoryRoot = Split-Path $PSScriptRoot
        $script:sourceManifest = Join-Path $script:repositoryRoot 'src/RetentionEngine/RetentionEngine.psd1'
        $script:builder = Join-Path $script:repositoryRoot 'tools/Build-Module.ps1'
        Import-Module $script:sourceManifest -Force
    }
)

Describe 'Module surface and standalone distribution' (
    {
        It 'exports only the supported public commands and keeps helpers private' (
            {
                $expected = @(
                    'Export-RetentionReportHtml'
                    'Get-RetentionBatchReport'
                    'Get-RetentionJob'
                    'Get-RetentionReport'
                    'Import-RetentionPolicyCsv'
                    'Invoke-RetentionCleanup'
                )
                $actual = @(Get-Command -Module RetentionEngine | Sort-Object Name | Select-Object -ExpandProperty Name)
                ($actual -join ',') | Should -Be ($expected -join ',')
                foreach ($name in 'Get-RetentionAttributes', 'Remove-RetentionCandidate', 'Write-RetentionHtmlFile')
                {
                    Get-Command -Name $name -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
                }
            }
        )

        It 'lists every runtime source file in the manifest and documents the cleanup entry point' (
            {
                $data = Import-PowerShellDataFile -LiteralPath $script:sourceManifest
                $moduleRoot = Split-Path $script:sourceManifest
                $files = @(Get-ChildItem -LiteralPath $moduleRoot -Recurse -File)
                $data.FileList.Count | Should -Be $files.Count
                foreach ($file in $files)
                {
                    $relative = [IO.Path]::GetRelativePath($moduleRoot, $file.FullName).Replace('\', '/')
                    $data.FileList | Should -Contain $relative
                }
                $help = Get-Help Invoke-RetentionCleanup -Examples
                $help.examples.example.Count | Should -BeGreaterThan 0
                (Get-Command Invoke-RetentionCleanup).Parameters.Keys | Should -Contain 'WhatIf'
                (Get-Command Invoke-RetentionCleanup).Parameters.Keys | Should -Contain 'Execute'
            }
        )

        It 'does not create build directories during WhatIf' (
            {
                $output = Join-Path $TestDrive 'preview-output'
                $null = & $script:builder -DestinationPath $output -WhatIf
                [IO.Directory]::Exists($output) | Should -BeFalse
            }
        )

        It 'builds only module runtime files and license, and refuses to overwrite a package' (
            {
                $output = Join-Path $TestDrive 'package-output'
                $package = & $script:builder -DestinationPath $output
                [IO.File]::Exists($package.ManifestPath) | Should -BeTrue
                [IO.File]::Exists((Join-Path $package.PackagePath 'LICENSE')) | Should -BeTrue
                $manifest = Import-PowerShellDataFile -LiteralPath $script:sourceManifest
                @(Get-ChildItem -LiteralPath $package.PackagePath -Recurse -File).Count | Should -Be ($manifest.FileList.Count + 1)
                [IO.Directory]::Exists((Join-Path $package.PackagePath 'tests')) | Should -BeFalse
                [IO.File]::Exists((Join-Path $package.PackagePath 'Remove-OldFiles.ps1')) | Should -BeFalse
                (
                    {
                        & $script:builder -DestinationPath $output
                    }
                ) | Should -Throw '*already exists*'
            }
        )

        It 'imports and plans from a copied package in a fresh PowerShell process outside the repository' (
            {
                $output = Join-Path $TestDrive 'isolated-output'
                $package = & $script:builder -DestinationPath $output
                $child = Join-Path $TestDrive 'verify-package.ps1'
                $code = @'
param([string]$Manifest)
$ErrorActionPreference = 'Stop'
Import-Module $Manifest -Force
$policy = [pscustomobject](
    @{
        PolicyId = 'package-check'
        RootPath = (Join-Path (Split-Path $Manifest) 'unavailable-scope')
        FilePattern = '*.log'
        RetentionDays = 30
        Recurse = $false
        Enabled = $false
    }
)
$result = Invoke-RetentionCleanup -Policy $policy
[pscustomobject](
    @{
        Status = $result.Status
        Mode = $result.Mode
        DeletedCount = $result.DeletedCount
        CommandCount = @(Get-Command -Module RetentionEngine).Count
    }
) | ConvertTo-Json -Compress
'@
                [IO.File]::WriteAllText($child, $code)
                $executable = Join-Path $PSHOME 'pwsh'
                if ($IsWindows)
                {
                    $executable += '.exe'
                }
                Push-Location $TestDrive
                try
                {
                    $json = & $executable -NoLogo -NoProfile -File $child -Manifest $package.ManifestPath
                    $LASTEXITCODE | Should -Be 0
                    $result = $json | ConvertFrom-Json
                    $result.Status | Should -Be 'Disabled'
                    $result.Mode | Should -Be 'ReportOnly'
                    $result.DeletedCount | Should -Be 0
                    $result.CommandCount | Should -Be 6
                }
                finally
                {
                    Pop-Location
                }
            }
        )
    }
)
