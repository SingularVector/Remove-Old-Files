function New-RetentionSqlConnectionString
{
    param(
        [string]$ServerInstance,
        [string]$Database
    )

    $builder = [System.Data.Common.DbConnectionStringBuilder]::new()
    $builder['Data Source'] = $ServerInstance
    $builder['Initial Catalog'] = $Database
    $builder['Integrated Security'] = $true
    $builder['Encrypt'] = $true
    $builder['TrustServerCertificate'] = $false
    $builder['Connect Timeout'] = 15
    $builder['Application Name'] = 'Remove-Old-Files'
    $builder['Persist Security Info'] = $false
    return $builder.ConnectionString
}
