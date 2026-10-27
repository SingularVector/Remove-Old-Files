function New-RetentionSqlConnection
{
    param(
        [string]$ServerInstance,
        [string]$Database,
        [pscredential]$Credential
    )

    if (-not $IsWindows)
    {
        throw [PlatformNotSupportedException]::new('Database commands are supported on Windows only.')
    }

    $connectionString = New-RetentionSqlConnectionString -ServerInstance $ServerInstance -Database $Database -SqlAuthentication:($null -ne $Credential)
    $connection = $null
    try
    {
        $connection = [System.Data.SqlClient.SqlConnection]::new($connectionString)
        if ($null -ne $Credential)
        {
            # SqlCredential accepts a read-only SecureString, not a plaintext password.
            $password = $Credential.Password.Copy()
            $password.MakeReadOnly()
            $connection.Credential = [System.Data.SqlClient.SqlCredential]::new($Credential.UserName, $password)
        }
        return $connection
    }
    catch
    {
        if ($null -ne $connection)
        {
            $connection.Dispose()
        }
        throw
    }
}
