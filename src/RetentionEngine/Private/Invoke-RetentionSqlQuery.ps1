function Invoke-RetentionSqlQuery
{
    param(
        [string]$ServerInstance,
        [string]$Database,
        [string]$Query
    )

    if (-not $IsWindows)
    {
        throw [PlatformNotSupportedException]::new('Database commands are supported on Windows only.')
    }

    Import-Module SqlServer -MinimumVersion 22.0 -ErrorAction Stop
    $connectionString = New-RetentionSqlConnectionString -ServerInstance $ServerInstance -Database $Database
    $parameters = (
        @{
            ConnectionString = $connectionString
            Query = $Query
            QueryTimeout = 30
            AbortOnError = $true
            DisableCommands = $true
            DisableVariables = $true
            OutputAs = 'DataRows'
            ErrorAction = 'Stop'
        }
    )
    SqlServer\Invoke-Sqlcmd @parameters
}
