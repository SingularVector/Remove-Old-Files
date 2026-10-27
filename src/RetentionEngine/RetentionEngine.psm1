Set-StrictMode -Version Latest

# Explicit lists keep the module's loading order and public surface reviewable.
$privateFiles = @(
    'New-RetentionSqlConnectionString.ps1'
    'Import-RetentionSqlClient.ps1'
    'New-RetentionSqlConnection.ps1'
    'Invoke-RetentionSqlQuery.ps1'
    'Get-RetentionAttributes.ps1'
    'Get-RetentionChildren.ps1'
    'Get-RetentionFile.ps1'
    'ConvertTo-RetentionHtmlText.ps1'
    'ConvertTo-RetentionHtmlTable.ps1'
    'Write-RetentionHtmlFile.ps1'
    'Test-RetentionExecutionCandidate.ps1'
    'Remove-RetentionCandidate.ps1'
)

$publicFiles = @(
    'Get-RetentionJob.ps1'
    'New-RetentionPolicy.ps1'
    'Get-RetentionReport.ps1'
    'Export-RetentionReportHtml.ps1'
    'Import-RetentionPolicyCsv.ps1'
    'Get-RetentionBatchReport.ps1'
    'Invoke-RetentionCleanup.ps1'
)

foreach ($file in $privateFiles)
{
    . (Join-Path (Join-Path $PSScriptRoot 'Private') $file)
}

foreach ($file in $publicFiles)
{
    . (Join-Path (Join-Path $PSScriptRoot 'Public') $file)
}

Export-ModuleMember -Function @(
    'Get-RetentionJob'
    'New-RetentionPolicy'
    'Get-RetentionReport'
    'Export-RetentionReportHtml'
    'Import-RetentionPolicyCsv'
    'Get-RetentionBatchReport'
    'Invoke-RetentionCleanup'
)
