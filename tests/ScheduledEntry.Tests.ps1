BeforeAll (
    {
        $script:entrySource = Join-Path $PSScriptRoot '../examples/Invoke-ScheduledRetentionJob.ps1'
        $script:executable = Join-Path $PSHOME 'pwsh'

        if ($IsWindows)
        {
            $script:executable += '.exe'
        }
    }
)

Describe 'Scheduled task process contract' (
    {
        BeforeEach (
            {
                $script:package = Join-Path $TestDrive ([guid]::NewGuid().ToString())
                $examples = Join-Path $script:package 'examples'
                $module = Join-Path $script:package 'src/RetentionEngine'
                $null = [IO.Directory]::CreateDirectory($examples)
                $null = [IO.Directory]::CreateDirectory($module)
                $script:entry = Join-Path $examples 'Invoke-ScheduledRetentionJob.ps1'
                Copy-Item -LiteralPath $script:entrySource -Destination $script:entry

                # A minimal fake module isolates process/parameter handling from SQL.
                # Filesystem deletion and real job behaviour have their own tests.
                $manifest = @'
@{
    RootModule        = 'RetentionEngine.psm1'
    ModuleVersion     = '2.0.0'
    FunctionsToExport = @('Invoke-RetentionCleanup')
}
'@

                $source = @'
function Invoke-RetentionCleanup
{
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$ServerInstance,
        [string]$Database,
        [string]$JobName,
        [pscredential]$Credential,
        [switch]$Execute
    )

    if ($JobName -eq 'Throw')
    {
        throw 'Synthetic SQL connection failure.'
    }

    $mode = switch ($true)
    {
        {
            $WhatIfPreference
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

    [pscustomobject](
        @{
            Status = $JobName
            Mode   = $mode
        }
    )
}
'@

                [IO.File]::WriteAllText((Join-Path $module 'RetentionEngine.psd1'), $manifest)
                [IO.File]::WriteAllText((Join-Path $module 'RetentionEngine.psm1'), $source)
            }
        )

        It 'returns process exit <ExitCode> for job status <Status>' -ForEach @(
            @{
                Status   = 'Completed'
                ExitCode = 0
            }
            @{
                Status   = 'Disabled'
                ExitCode = 0
            }
            @{
                Status   = 'Partial'
                ExitCode = 1
            }
            @{
                Status   = 'Failed'
                ExitCode = 1
            }
            @{
                Status   = 'Blocked'
                ExitCode = 1
            }
        ) (
            {
                $json = & $script:executable -NoProfile -File $script:entry -ServerInstance SQL01 -Database Automation -JobName $Status
                $LASTEXITCODE | Should -Be $ExitCode
                $result = $json | ConvertFrom-Json
                $result.Status | Should -Be $Status
                $result.Mode | Should -Be 'ReportOnly'
            }
        )

        It 'passes execute and preview intent through to the cleanup command' (
            {
                $json = & $script:executable -NoProfile -File $script:entry -ServerInstance SQL01 -Database Automation -JobName Completed -Execute -WhatIf
                $LASTEXITCODE | Should -Be 0
                ($json | ConvertFrom-Json).Mode | Should -Be 'WhatIf'
            }
        )

        It 'returns a nonzero exit code and useful stderr when setup throws' (
            {
                $errorFile = Join-Path $script:package 'stderr.txt'
                $null = & $script:executable -NoProfile -File $script:entry -ServerInstance SQL01 -Database Automation -JobName Throw 2> $errorFile
                $LASTEXITCODE | Should -Be 1
                Get-Content -LiteralPath $errorFile -Raw | Should -Match 'Synthetic SQL connection failure'
            }
        )
    }
)
