@{
    RootModule = 'RetentionEngine.psm1'
    ModuleVersion = '2.0.0'
    GUID = '8400280e-fd13-44e4-8ae0-ea380b9ba636'
    Author = 'SingularVector'
    Description = 'Report-only filesystem retention engine. Development milestone; no deletion support.'
    PowerShellVersion = '7.4'
    FunctionsToExport = @('Get-RetentionReport', 'Export-RetentionReportHtml', 'Import-RetentionPolicyCsv', 'Get-RetentionBatchReport')
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    PrivateData = @{ PSData = @{ Prerelease = 'alpha1'; Tags = @('Retention', 'Reporting') } }
}
