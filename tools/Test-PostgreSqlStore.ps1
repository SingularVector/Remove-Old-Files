#Requires -Version 7.4
<#
.SYNOPSIS
Tests the prototype store in a disposable, network-isolated PostgreSQL container.
.DESCRIPTION
Requires a running Docker engine. No host ports, bind mounts or production data.
The container and memory-backed database are removed when the script finishes.
#>
[CmdletBinding()]
param(
    [ValidatePattern('^postgres:[A-Za-z0-9_.-]+$')]
    [string]$DockerImage = 'postgres:18-alpine'
)

function Invoke-ContractSql
{
    param([string]$Container, [string]$Sql)

    $output = $Sql | & docker exec -i $Container psql -X -q -A -t -U postgres -d retention_contract_test -v ON_ERROR_STOP=1 2>&1
    if ($LASTEXITCODE -ne 0)
    {
        throw ($output -join [Environment]::NewLine)
    }
    return $output
}

function Start-ContractClient
{
    param([string]$Container, [string]$Sql)

    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = 'docker'
    foreach ($argument in @('exec', '-i', $Container, 'psql', '-X', '-q', '-A', '-t', '-U', 'postgres', '-d', 'retention_contract_test', '-v', 'ON_ERROR_STOP=1'))
    {
        $start.ArgumentList.Add($argument)
    }
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.UseShellExecute = $false
    $process = [Diagnostics.Process]::Start($start)
    $process.StandardInput.WriteLine($Sql)
    $process.StandardInput.Close()
    return $process
}

$repository = Split-Path $PSScriptRoot
$null = & docker version --format '{{.Server.Version}}' 2>&1
if ($LASTEXITCODE -ne 0)
{
    throw 'A running Docker engine is required for disposable PostgreSQL tests.'
}

$password = [guid]::NewGuid().ToString('N')
$container = $null
try
{
    $container = & docker run --detach --rm --network none --tmpfs /var/lib/postgresql:rw,size=256m -e "POSTGRES_PASSWORD=$password" -e POSTGRES_DB=retention_contract_test $DockerImage
    if ($LASTEXITCODE -ne 0)
    {
        throw 'Could not create the disposable PostgreSQL container.'
    }
    $container = $container.Trim()
    $ready = $false
    for ($attempt = 0; $attempt -lt 60; $attempt++)
    {
        $null = & docker exec $container pg_isready -U postgres -d retention_contract_test 2>&1
        if ($LASTEXITCODE -eq 0)
        {
            $ready = $true
            break
        }
        Start-Sleep -Milliseconds 500
    }
    if (-not $ready)
    {
        throw 'Disposable PostgreSQL did not become ready.'
    }

    $migration = Get-Content -LiteralPath (Join-Path $repository 'database/postgresql/001_initial.sql') -Raw
    $null = Invoke-ContractSql -Container $container -Sql $migration
    $checks = Get-Content -LiteralPath (Join-Path $repository 'tests/database/001_contract.sql') -Raw
    $results = Invoke-ContractSql -Container $container -Sql $checks
    foreach ($line in $results)
    {
        if ([string]$line -like 'DATABASE_ASSERTIONS_PASSED=*')
        {
            Write-Output $line
        }
    }

    $claim = "SELECT run_id FROM retention.claim_report_run('00000000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-000000000001', 1);"
    $first = Start-ContractClient -Container $container -Sql ("BEGIN; " + $claim + ' SELECT pg_sleep(1); COMMIT;')
    $second = Start-ContractClient -Container $container -Sql $claim
    try
    {
        $firstOutput = $first.StandardOutput.ReadToEnd()
        $firstError = $first.StandardError.ReadToEnd()
        $secondOutput = $second.StandardOutput.ReadToEnd()
        $secondError = $second.StandardError.ReadToEnd()
        $first.WaitForExit()
        $second.WaitForExit()
        $codes = @($first.ExitCode, $second.ExitCode)
        $successCount = @($codes | Where-Object (
                {
                    $_ -eq 0
                }
            )).Count
        if ($successCount -ne 1)
        {
            throw "Expected exactly one successful concurrent claim. Client errors: $firstError $secondError"
        }
        if (-not ($firstError + $secondError).Contains('Scope has an active or unresolved run'))
        {
            throw 'The competing client did not fail for the expected scope-conflict reason.'
        }
        $active = Invoke-ContractSql -Container $container -Sql "SELECT count(*) FROM retention.runs WHERE scope_id = '00000000-0000-0000-0000-000000000004' AND state = 'Running';"
        if ([string]$active -ne '1')
        {
            throw 'Concurrent clients did not leave exactly one active run.'
        }
        Write-Output 'CONCURRENT_CLAIM_CHECK_PASSED=1'
    }
    finally
    {
        $first.Dispose()
        $second.Dispose()
    }

    $version = Invoke-ContractSql -Container $container -Sql 'SHOW server_version;'
    $image = & docker inspect --format '{{.Image}}' $container
    Write-Output "POSTGRES_VERSION=$version"
    Write-Output "IMAGE_ID=$image"
}
finally
{
    if (-not [string]::IsNullOrWhiteSpace($container))
    {
        $null = & docker rm --force $container 2>&1
    }
}
