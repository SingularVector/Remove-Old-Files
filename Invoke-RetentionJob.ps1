#Requires -Version 7.4
<#
.SYNOPSIS
Runs one configured SQL cleanup job and returns a useful process exit code.
.DESCRIPTION
Intended for Windows Task Scheduler. Defaults to a read-only plan. Pass Execute
for deletion; combine Execute and WhatIf for a preview. Results are written as
JSON to standard output. Completed/Disabled return exit code 0; all other results
or terminating errors return 1. The script does not install dependencies or jobs.
.PARAMETER Credential
Optional SQL credential when invoked from PowerShell. Scheduled tasks normally
use integrated authentication as their configured Windows account.
.EXAMPLE
./Invoke-RetentionJob.ps1 -ServerInstance SQL01 -Database Automation -JobName AppLogs -Execute
Runs unattended, using the task account and the complete module beside the script.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [string]$ServerInstance,

    [Parameter(Mandatory)]
    [string]$Database,

    [Parameter(Mandatory)]
    [string]$JobName,

    [pscredential]$Credential,
    [switch]$Execute
)

$ErrorActionPreference = 'Stop'

try
{
    Import-Module (Join-Path $PSScriptRoot 'src/RetentionEngine/RetentionEngine.psd1') -Force

    # Scheduled runs must not wait for prompts. An explicit Confirm switch still
    # enables interactive per-file confirmation when an engineer requests it.
    $confirmation = $false

    if ($PSBoundParameters.ContainsKey('Confirm'))
    {
        $confirmation = [bool]$PSBoundParameters['Confirm']
    }

    $parameters =
    @{
        ServerInstance = $ServerInstance
        Database       = $Database
        JobName        = $JobName
        Credential     = $Credential
        Execute        = [bool]$Execute
        WhatIf         = [bool]$WhatIfPreference
        Confirm        = $confirmation
    }

    $result = Invoke-RetentionCleanup @parameters

    $result | ConvertTo-Json -Depth 16

    # Returning an object alone does not tell Task Scheduler that a run failed.
    switch ($result.Status)
    {
        {
            $_ -in 'Completed', 'Disabled'
        }
        {
            exit 0
        }
        default
        {
            exit 1
        }
    }
}
catch
{
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
