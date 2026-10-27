function Get-RetentionJob
{
    <#
    .SYNOPSIS
    Lists job names configured in the SQL Server cleanup-rules table.
    .DESCRIPTION
    Uses the current Windows account by default, or an explicit SQL credential. Returns one
    object per configured job, including disabled-only jobs unless EnabledOnly is
    specified. This command never runs cleanup or updates last-execution status.
    Uses the SQL client supplied with PowerShell on Windows; no SQL module is required.
    .PARAMETER ServerInstance
    SQL Server instance hosting the existing automation database.
    .PARAMETER Database
    Existing database containing dbo.CleanupRules.
    .PARAMETER Credential
    Optional SQL Server login. Omit to use the current Windows account.
    .PARAMETER EnabledOnly
    Lists only jobs with at least one enabled cleanup rule.
    .EXAMPLE
    Get-RetentionJob -ServerInstance 'SQL01' -Database 'Automation'
    Shows configured names and their total/enabled rule counts for the SE to review.
    .EXAMPLE
    Get-RetentionJob -ServerInstance 'SQL01' -Database 'Automation' -EnabledOnly
    Lists names that currently have enabled rules.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ServerInstance,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Database,

        [pscredential]$Credential,

        [switch]$EnabledOnly
    )

    if ([string]::IsNullOrWhiteSpace($ServerInstance) -or [string]::IsNullOrWhiteSpace($Database))
    {
        throw [ArgumentException]::new('ServerInstance and Database must not be blank.')
    }

    $query = @'
SELECT
    JobName,
    COUNT_BIG(*) AS RuleCount,
    SUM(CONVERT(bigint, Enabled)) AS EnabledRuleCount
FROM dbo.CleanupRules
GROUP BY JobName
'@
    if ($EnabledOnly)
    {
        $query += "`nHAVING SUM(CONVERT(bigint, Enabled)) > 0"
    }
    $query += "`nORDER BY JobName;"

    $rows = @(Invoke-RetentionSqlQuery -ServerInstance $ServerInstance -Database $Database -Query $query -Credential $Credential)
    foreach ($row in $rows)
    {
        [pscustomobject](
            @{
                JobName = [string]$row.JobName
                RuleCount = [long]$row.RuleCount
                EnabledRuleCount = [long]$row.EnabledRuleCount
            }
        )
    }
}
