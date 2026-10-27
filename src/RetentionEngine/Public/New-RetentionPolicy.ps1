function New-RetentionPolicy
{
    <#
    .SYNOPSIS
    Creates one cleanup rule in the SQL Server configuration table.
    .DESCRIPTION
    Saves a new rule and returns the database's inserted values. Does not scan or
    delete files, schedule a job, or change existing rules. Last-execution fields
    start NULL. WhatIf validates the settings without connecting to SQL Server.
    .PARAMETER JobName
    Logical job name. Multiple rules may share this name.
    .PARAMETER CleanupPath
    Absolute Windows directory on the machine that will execute the job. Does not
    need to exist on the configuring machine. Drive/share roots are not allowed.
    .PARAMETER FileExtension
    Bare extension such as log or tar.gz. Supply an empty string explicitly for all files.
    .PARAMETER RetentionDays
    Files become eligible strictly after this many days since their last write.
    .PARAMETER IncludeSubfolders
    Includes subdirectories when this rule executes.
    .PARAMETER Disabled
    Creates a disabled rule for later review. Rules are enabled by default.
    .PARAMETER Credential
    Optional SQL login; omit to use the current Windows identity.
    .EXAMPLE
    New-RetentionPolicy -ServerInstance SQL01 -Database Automation -JobName AppLogs -CleanupPath 'D:\Logs' -FileExtension log -RetentionDays 30 -IncludeSubfolders -WhatIf
    Previews creation without contacting SQL Server or touching files.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ServerInstance,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Database,

        [Parameter(Mandatory)]
        [ValidateLength(1, 128)]
        [string]$JobName,

        [Parameter(Mandatory)]
        [ValidateLength(1, 2048)]
        [string]$CleanupPath,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [ValidateLength(0, 64)]
        [ValidatePattern('^$|^[\p{L}\p{N}_-]+(?:\.[\p{L}\p{N}_-]+)*$')]
        [string]$FileExtension,

        [Parameter(Mandatory)]
        [ValidateRange(1, 36500)]
        [int]$RetentionDays,

        [switch]$IncludeSubfolders,
        [switch]$Disabled,
        [pscredential]$Credential
    )

    foreach ($setting in $ServerInstance, $Database, $JobName)
    {
        if ([string]::IsNullOrWhiteSpace($setting))
        {
            throw [ArgumentException]::new('ServerInstance, Database and JobName must not be blank.')
        }
    }

    # Validate Windows syntax without looking at a directory on the configuring machine.
    $path = $CleanupPath.Replace('/', '\').TrimEnd('\')
    switch -Regex ($path)
    {
        '^[A-Za-z]:\\[^\\]'
        {
            if ($path.Substring(2).Contains(':'))
            {
                throw [ArgumentException]::new('CleanupPath must not contain a device or stream path.')
            }
            break
        }
        '^\\\\[^\\]+\\[^\\]+\\[^\\]'
        {
            if ($path.StartsWith('\\?\') -or $path.StartsWith('\\.\') -or $path.Contains(':'))
            {
                throw [ArgumentException]::new('CleanupPath must not contain a device or stream path.')
            }
            break
        }
        default
        {
            throw [ArgumentException]::new('CleanupPath must be an absolute Windows directory below a drive or share root.')
        }
    }
    if (($path -split '\\') -match '(^\.\.?$|[ .]$)' -or $path.IndexOfAny([char[]]'*?<>|"') -ge 0 -or $path -match '[\x00-\x1F]')
    {
        throw [ArgumentException]::new('CleanupPath must not contain traversal, wildcards or invalid path characters.')
    }

    $query = @'
INSERT INTO dbo.CleanupRules
    (JobName, CleanupPath, FileExtension, RetentionDays, IncludeSubfolders, Enabled)
OUTPUT INSERTED.*
VALUES
    (@JobName, @CleanupPath, @FileExtension, @RetentionDays, @IncludeSubfolders, @Enabled);
'@
    $parameters = @(
        [pscustomobject](
            @{
                Name   = '@JobName'
                DbType = [Data.DbType]::String
                Size   = 128
                Value  = $JobName
            }
        )
        [pscustomobject](
            @{
                Name   = '@CleanupPath'
                DbType = [Data.DbType]::String
                Size   = 2048
                Value  = $path
            }
        )
        [pscustomobject](
            @{
                Name   = '@FileExtension'
                DbType = [Data.DbType]::String
                Size   = 64
                Value  = $FileExtension
            }
        )
        [pscustomobject](
            @{
                Name   = '@RetentionDays'
                DbType = [Data.DbType]::Int32
                Size   = 0
                Value  = $RetentionDays
            }
        )
        [pscustomobject](
            @{
                Name   = '@IncludeSubfolders'
                DbType = [Data.DbType]::Boolean
                Size   = 0
                Value  = [bool]$IncludeSubfolders
            }
        )
        [pscustomobject](
            @{
                Name   = '@Enabled'
                DbType = [Data.DbType]::Boolean
                Size   = 0
                Value  = -not $Disabled
            }
        )
    )

    if ($PSCmdlet.ShouldProcess("$ServerInstance/$Database : $JobName : $path", 'Create cleanup rule'))
    {
        $sqlParameters = (
            @{
                ServerInstance = $ServerInstance
                Database       = $Database
                Query          = $query
                Credential     = $Credential
                Parameters     = $parameters
            }
        )
        Invoke-RetentionSqlQuery @sqlParameters
    }
}
