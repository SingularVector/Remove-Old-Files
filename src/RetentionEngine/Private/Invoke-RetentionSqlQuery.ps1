function Invoke-RetentionSqlQuery
{
    param(
        [string]$ServerInstance,
        [string]$Database,
        [string]$Query,
        [pscredential]$Credential,
        [object[]]$Parameters = @()
    )

    $connection = $null
    $command = $null
    $reader = $null
    $rows = [System.Collections.Generic.List[object]]::new()
    try
    {
        $connection = New-RetentionSqlConnection -ServerInstance $ServerInstance -Database $Database -Credential $Credential
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandText = $Query
        $command.CommandTimeout = 30
        foreach ($definition in $Parameters)
        {
            $parameter = $command.CreateParameter()
            $parameter.ParameterName = $definition.Name
            $parameter.DbType = $definition.DbType
            $parameter.Size = $definition.Size
            $parameter.Value = $definition.Value
            $null = $command.Parameters.Add($parameter)
        }
        $reader = $command.ExecuteReader()
        while ($reader.Read())
        {
            $values = [System.Collections.Specialized.OrderedDictionary]::new()
            for ($column = 0; $column -lt $reader.FieldCount; $column++)
            {
                $value = $null
                if (-not $reader.IsDBNull($column))
                {
                    $value = $reader.GetValue($column)
                }
                $values[$reader.GetName($column)] = $value
            }
            $rows.Add([pscustomobject]$values)
        }
    }
    finally
    {
        # Nested finally blocks also release outer resources if disposal itself fails.
        try
        {
            if ($null -ne $reader)
            {
                $reader.Dispose()
            }
        }
        finally
        {
            try
            {
                if ($null -ne $command)
                {
                    $command.Dispose()
                }
            }
            finally
            {
                if ($null -ne $connection)
                {
                    $connection.Dispose()
                }
            }
        }
    }

    # Publish results only after reading completes successfully.
    return $rows.ToArray()
}
