@{
    RootModule = 'RetentionEngine.psm1'
    ModuleVersion = '2.0.0'
    GUID = '8400280e-fd13-44e4-8ae0-ea380b9ba636'
    Author = 'SingularVector'
    Description = 'Filesystem retention engine with reporting, CSV migration and explicitly opted-in cleanup.'
    PowerShellVersion = '7.4'
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
