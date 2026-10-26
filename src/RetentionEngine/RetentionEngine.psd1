@{
    RootModule = 'RetentionEngine.psm1'
    ModuleVersion = '2.0.0'
    GUID = '8400280e-fd13-44e4-8ae0-ea380b9ba636'
    Author = 'SingularVector'
    Description = 'Filesystem retention engine with reporting, CSV migration and explicitly opted-in cleanup.'
    PowerShellVersion = '7.4'
    FileList = @(
        'RetentionEngine.psd1'
        'RetentionEngine.psm1'
        'Private/ConvertTo-RetentionHtmlTable.ps1'
        'Private/ConvertTo-RetentionHtmlText.ps1'
        'Private/Get-RetentionAttributes.ps1'
        'Private/Get-RetentionChildren.ps1'
        'Private/Get-RetentionFile.ps1'
        'Private/Remove-RetentionCandidate.ps1'
        'Private/Test-RetentionExecutionCandidate.ps1'
        'Private/Write-RetentionHtmlFile.ps1'
        'Public/Export-RetentionReportHtml.ps1'
        'Public/Get-RetentionBatchReport.ps1'
        'Public/Get-RetentionReport.ps1'
        'Public/Import-RetentionPolicyCsv.ps1'
        'Public/Invoke-RetentionCleanup.ps1'
    )
    FunctionsToExport = @('Get-RetentionReport', 'Export-RetentionReportHtml', 'Import-RetentionPolicyCsv', 'Get-RetentionBatchReport', 'Invoke-RetentionCleanup')
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    PrivateData = (
        @{
            PSData = (
                @{
                    Prerelease = 'alpha1'
                    Tags = @('Retention', 'Reporting')
                }
            )
        }
    )
}
