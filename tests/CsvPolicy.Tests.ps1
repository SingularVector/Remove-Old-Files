BeforeAll (
    {
        Import-Module (Join-Path $PSScriptRoot '../src/RetentionEngine/RetentionEngine.psd1') -Force
        function Write-PolicyCsv
        {
            param([object[]]$Rows)
            $Rows | Export-Csv -LiteralPath $script:csv -NoTypeInformation
        }
    }
)
Describe 'Legacy CSV migration and report-only batches' (
    {
        BeforeEach (
            {
                $script:base = Join-Path $TestDrive ([guid]::NewGuid().ToString())
                if ($IsMacOS -and ($script:base.StartsWith('/var/') -or $script:base.StartsWith('/tmp/')))
                {
                    $script:base = '/private' + $script:base
                }

                [void][IO.Directory]::CreateDirectory($script:base)
                $script:csv = Join-Path $script:base 'policies.csv'
                $script:first = Join-Path $script:base 'logs'
                $script:second = Join-Path $script:base 'exports'
                $script:row = [pscustomobject](
                    @{
                        CleanupPath = $script:first
                        FileExtension = 'log'
                        AgeTolerance = '30'
                        IncludeSubFolders = '0'
                    }
                )
            }
        )
        It 'maps legacy fields without touching target directories' (
            {
                Write-PolicyCsv @($script:row)
                Mock Get-RetentionAttributes -ModuleName RetentionEngine (
                    {
                        throw 'Target filesystem must not be accessed.'
                    }
                )
                $r = Import-RetentionPolicyCsv $script:csv
                $r.Status | Should -Be 'Ready'
                $r.Policies[0].Recurse | Should -BeFalse
                $r.Policies[0].RetentionDays | Should -Be 30
                $r.Policies[0].FilePattern | Should -Be '*.log'
                $r.Policies[0].Enabled | Should -BeTrue
                $r.Policies[0].SourceRow | Should -Be 2
                $r.Policies[0].SourceFile | Should -Be $script:csv
                Should -Invoke Get-RetentionAttributes -ModuleName RetentionEngine -Times 0 -Exactly
            }
        )
        It 'reports each empty-field default and explicit all-filename matching' (
            {
                $script:row.FileExtension = ''
                $script:row.AgeTolerance = ''
                $script:row.IncludeSubFolders = ''
                Write-PolicyCsv @($script:row)
                $r = Import-RetentionPolicyCsv $script:csv
                $r.IsReady | Should -BeTrue
                $r.Warnings.Count | Should -Be 3
                $r.Policies[0].FilePattern | Should -Be '*'
                $r.Policies[0].RetentionDays | Should -Be 90
                $r.Policies[0].Recurse | Should -BeFalse
            }
        )
        It 'trims fields and supports quoted paths containing commas' (
            {
                $script:row.CleanupPath = '  ' + (Join-Path $script:base 'with,comma') + '  '
                $script:row.FileExtension = ' tar.gz '
                $script:row.AgeTolerance = ' 7 '
                $script:row.IncludeSubFolders = ' 1 '
                Write-PolicyCsv @($script:row)
                $r = Import-RetentionPolicyCsv $script:csv
                $r.IsReady | Should -BeTrue
                $r.Policies[0].FilePattern | Should -Be '*.tar.gz'
                $r.Policies[0].Recurse | Should -BeTrue
                $r.Policies[0].RootPath | Should -Match 'with,comma$'
            }
        )
        It 'rejects <Field>=<Value>' -TestCases @(
            (
                @{
                    Field='AgeTolerance'
                    Value='-1'
                }
            ), (
                @{
                    Field='AgeTolerance'
                    Value='0'
                }
            ),
            (
                @{
                    Field='AgeTolerance'
                    Value='1.5'
                }
            ), (
                @{
                    Field='AgeTolerance'
                    Value='36501'
                }
            ),
            (
                @{
                    Field='AgeTolerance'
                    Value='999999999999'
                }
            ), (
                @{
                    Field='IncludeSubFolders'
                    Value='false'
                }
            ),
            (
                @{
                    Field='IncludeSubFolders'
                    Value='2'
                }
            ), (
                @{
                    Field='FileExtension'
                    Value='*.log'
                }
            ),
            (
                @{
                    Field='FileExtension'
                    Value='../log'
                }
            ), (
                @{
                    Field='CleanupPath'
                    Value=''
                }
            ),
            (
                @{
                    Field='CleanupPath'
                    Value='relative'
                }
            )
        ) (
            {
                param($Field,$Value)
                $script:row.$Field=$Value
                Write-PolicyCsv @($script:row)
                $r=Import-RetentionPolicyCsv $script:csv
                $r.IsReady | Should -BeFalse
                $r.Errors[0].Scope | Should -Be 'Row'
                $r.Errors[0].SourceRow | Should -Be 2
                $r.Policies.Count | Should -Be 0
            }
        )
        It 'rejects <Kind> headers' -TestCases @(
            (
                @{
                    Kind='missing'
                    Header='CleanupPath,FileExtension,AgeTolerance'
                }
            ),
            (
                @{
                    Kind='duplicate'
                    Header='CleanupPath,FileExtension,AgeTolerance,CleanupPath'
                }
            ),
            (
                @{
                    Kind='unknown'
                    Header='CleanupPath,FileExtension,AgeTolerance,IncludeSubFolders,Enabled'
                }
            )
        ) (
            {
                param($Kind,$Header)
                [IO.File]::WriteAllText($script:csv,$Header+"`n")
                $r=Import-RetentionPolicyCsv $script:csv
                $r.IsReady | Should -BeFalse
                $r.Errors[0].Scope | Should -Be 'File'
            }
        )
        It 'blocks malformed quoting and wrong field counts' (
            {
                foreach($body in @('"unclosed','one,two,three','one,two,three,four,five'))
                {
                    [IO.File]::WriteAllText($script:csv,"CleanupPath,FileExtension,AgeTolerance,IncludeSubFolders`n"+$body)
                    (Import-RetentionPolicyCsv $script:csv).IsReady | Should -BeFalse
                }
            }
        )
        It 'rejects empty files, header-only files and missing input' (
            {
                (Import-RetentionPolicyCsv $script:csv).Errors[0].Scope | Should -Be 'File'
                [IO.File]::WriteAllText($script:csv,'')
                (Import-RetentionPolicyCsv $script:csv).IsReady | Should -BeFalse
                [IO.File]::WriteAllText($script:csv,'CleanupPath,FileExtension,AgeTolerance,IncludeSubFolders')
                (Import-RetentionPolicyCsv $script:csv).IsReady | Should -BeFalse
            }
        )
        It 'detects duplicate and nested roots even with differing patterns and nonrecursive policies' (
            {
                foreach($root in @($script:first,(Join-Path $script:first 'child')))
                {
                    $other=[pscustomobject](
                        @{
                            CleanupPath=$root
                            FileExtension='txt'
                            AgeTolerance='7'
                            IncludeSubFolders='0'
                        }
                    )
                    Write-PolicyCsv @($script:row,$other)
                    $r=Import-RetentionPolicyCsv $script:csv
                    $r.IsReady | Should -BeFalse
                    $r.Overlaps.Count | Should -Be 1
                    $r.Overlaps[0].LeftRow | Should -Be 2
                    $r.Overlaps[0].RightRow | Should -Be 3
                }
            }
        )
        It 'does not confuse sibling path prefixes' (
            {
                $other=[pscustomobject](
                    @{
                        CleanupPath=($script:first+'-archive')
                        FileExtension='log'
                        AgeTolerance='7'
                        IncludeSubFolders='1'
                    }
                )
                Write-PolicyCsv @($script:row,$other)
                (Import-RetentionPolicyCsv $script:csv).IsReady | Should -BeTrue
            }
        )
        It 'blocks all scans when one row is invalid, retaining accepted policies for review' (
            {
                $other=[pscustomobject](
                    @{
                        CleanupPath=$script:second
                        FileExtension='log'
                        AgeTolerance='invalid'
                        IncludeSubFolders='1'
                    }
                )
                Write-PolicyCsv @($script:row,$other)
                Mock Get-RetentionAttributes -ModuleName RetentionEngine (
                    {
                        throw 'Must not scan any target.'
                    }
                )
                $r=Get-RetentionBatchReport $script:csv
                $r.Status | Should -Be 'Failed'
                $r.Import.Policies.Count | Should -Be 1
                $r.ReportCount | Should -Be 0
                Should -Invoke Get-RetentionAttributes -ModuleName RetentionEngine -Times 0 -Exactly
            }
        )
        It 'blocks all scans when scopes overlap' (
            {
                Write-PolicyCsv @($script:row,$script:row)
                Mock Get-RetentionAttributes -ModuleName RetentionEngine (
                    {
                        throw 'Must not scan any target.'
                    }
                )
                $r=Get-RetentionBatchReport $script:csv
                $r.ReportCount | Should -Be 0
                $r.Import.Overlaps.Count | Should -Be 1
                Should -Invoke Get-RetentionAttributes -ModuleName RetentionEngine -Times 0 -Exactly
            }
        )
        It 'scans disjoint policies with one shared evaluation time and reports runtime failures' (
            {
                [void][IO.Directory]::CreateDirectory($script:first)
                $file=Join-Path $script:first 'old.log'
                [IO.File]::WriteAllText($file,'sample')
                [IO.File]::SetLastWriteTimeUtc($file,[datetimeoffset]::Parse('2026-08-01T00:00:00Z').UtcDateTime)
                $other=[pscustomobject](
                    @{
                        CleanupPath=$script:second
                        FileExtension='txt'
                        AgeTolerance='7'
                        IncludeSubFolders='1'
                    }
                )
                Write-PolicyCsv @($script:row,$other)
                $now=[datetimeoffset]'2026-10-26T12:00:00Z'
                $r=Get-RetentionBatchReport $script:csv -EvaluationTimeUtc $now
                $r.Status | Should -Be 'Partial'
                $r.ReportCount | Should -Be 2
                $r.Reports[0].CandidateCount | Should -Be 1
                $r.Reports[1].Status | Should -Be 'Failed'
                $r.Reports[0].EvaluationTimeUtc | Should -Be $r.Reports[1].EvaluationTimeUtc
                $r.DeletedCount | Should -Be 0
                [IO.File]::ReadAllText($file) | Should -Be 'sample'
                [void][IO.Directory]::CreateDirectory($script:second)
                (Get-RetentionBatchReport $script:csv).Status | Should -Be 'Completed'
            }
        )
        It 'marks a batch with no accessible policy roots as Failed' (
            {
                Write-PolicyCsv @($script:row)
                (Get-RetentionBatchReport $script:csv).Status | Should -Be 'Failed'
            }
        )
    }
)
