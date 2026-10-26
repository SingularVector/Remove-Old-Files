BeforeAll (
    {
        Import-Module (Join-Path $PSScriptRoot '../src/RetentionEngine/RetentionEngine.psd1') -Force
        function New-ExecutionFixture
        {
            param([string]$Name = 'old.log')
            $path = Join-Path $script:root $Name
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
            [IO.File]::WriteAllText($path, 'disposable fixture')
            [IO.File]::SetLastWriteTimeUtc($path, [datetime]::UtcNow.AddDays(-40))
            return $path
        }
    }
)

Describe 'Controlled single-policy cleanup' (
    {
        BeforeEach (
            {
                $script:root = Join-Path (Join-Path $TestDrive ([guid]::NewGuid().ToString())) 'scope'
                if ($IsMacOS -and ($script:root.StartsWith('/var/') -or $script:root.StartsWith('/tmp/')))
                {
                    $script:root = '/private' + $script:root
                }

                [void][IO.Directory]::CreateDirectory($script:root)
                $script:policy = [pscustomobject](
                    @{
                        PolicyId = 'execution-test'
                        RootPath = $script:root
                        FilePattern = '*.log'
                        RetentionDays = 30
                        Recurse = $true
                        Enabled = $true
                    }
                )
            }
        )

        It 'plans by default and never invokes removal' (
            {
                $file = New-ExecutionFixture
                Mock Remove-RetentionCandidate -ModuleName RetentionEngine (
                    {
                        throw 'No write expected.'
                    }
                )
                $result = Invoke-RetentionCleanup -Policy $script:policy
                $result.Mode | Should -Be 'ReportOnly'
                $result.Actions[0].Status | Should -Be 'Planned'
                $result.DeletedCount | Should -Be 0
                $result.ScanReport.Mode | Should -Be 'ReportOnly'
                [IO.File]::Exists($file) | Should -BeTrue
                Should -Invoke Remove-RetentionCandidate -ModuleName RetentionEngine -Times 0 -Exactly
            }
        )

        It 'honours Execute plus WhatIf without removing files' (
            {
                $file = New-ExecutionFixture
                Mock Remove-RetentionCandidate -ModuleName RetentionEngine (
                    {
                        throw 'WhatIf must prevent writes.'
                    }
                )
                $result = Invoke-RetentionCleanup -Policy $script:policy -Execute -WhatIf
                $result.Mode | Should -Be 'WhatIf'
                $result.DeletedCount | Should -Be 0
                $result.Actions[0].Reason | Should -Be 'WhatIf'
                [IO.File]::Exists($file) | Should -BeTrue
                Should -Invoke Remove-RetentionCandidate -ModuleName RetentionEngine -Times 0 -Exactly
            }
        )

        It 'deletes only eligible disposable files after explicit opt-in' (
            {
                $old = New-ExecutionFixture
                $recent = New-ExecutionFixture 'recent.log'
                [IO.File]::SetLastWriteTimeUtc($recent, [datetime]::UtcNow)
                $other = New-ExecutionFixture 'other.txt'
                $result = Invoke-RetentionCleanup -Policy $script:policy -Execute -Confirm:$false
                $result.Mode | Should -Be 'Execute'
                $result.Status | Should -Be 'Completed'
                $result.DeletedCount | Should -Be 1
                $result.DeletedBytesObserved | Should -Be 18
                $result.Actions[0].Status | Should -Be 'Deleted'
                [IO.File]::Exists($old) | Should -BeFalse
                [IO.File]::Exists($recent) | Should -BeTrue
                [IO.File]::Exists($other) | Should -BeTrue
                [IO.Directory]::Exists($script:root) | Should -BeTrue
                $result.ScanReport.Mode | Should -Be 'PreExecutionSnapshot'
            }
        )

        It 'blocks execution for invalid or incomplete scans' (
            {
                $file = New-ExecutionFixture
                [void][IO.Directory]::CreateDirectory((Join-Path $script:root 'blocked'))
                Mock Get-RetentionChildren -ModuleName RetentionEngine (
                    {
                        throw [UnauthorizedAccessException]::new('Denied.')
                    }
                ) -ParameterFilter (
                    {
                        [IO.Path]::GetFileName($LiteralPath) -eq 'blocked'
                    }
                )
                Mock Remove-RetentionCandidate -ModuleName RetentionEngine (
                    {
                        throw 'Blocked scans must not write.'
                    }
                )
                $result = Invoke-RetentionCleanup -Policy $script:policy -Execute -Confirm:$false
                $result.Status | Should -Be 'Blocked'
                $result.ScanReport.Status | Should -Be 'Partial'
                $result.DeletedCount | Should -Be 0
                [IO.File]::Exists($file) | Should -BeTrue
                Should -Invoke Remove-RetentionCandidate -ModuleName RetentionEngine -Times 0 -Exactly
            }
        )

        It 'does not execute disabled or invalid policies' (
            {
                Mock Remove-RetentionCandidate -ModuleName RetentionEngine (
                    {
                        throw 'No removal expected.'
                    }
                )
                $script:policy.Enabled = $false
                (Invoke-RetentionCleanup $script:policy -Execute -Confirm:$false).Status | Should -Be 'Disabled'
                $script:policy.RetentionDays = 0
                (Invoke-RetentionCleanup $script:policy -Execute -Confirm:$false).Status | Should -Be 'Blocked'
                Should -Invoke Remove-RetentionCandidate -ModuleName RetentionEngine -Times 0 -Exactly
            }
        )

        It 'records removal failure without counting a successful deletion' (
            {
                $file = New-ExecutionFixture
                Mock Remove-RetentionCandidate -ModuleName RetentionEngine (
                    {
                        throw [UnauthorizedAccessException]::new('Delete denied.')
                    }
                )
                $result = Invoke-RetentionCleanup $script:policy -Execute -Confirm:$false
                $result.Status | Should -Be 'Failed'
                $result.DeletedCount | Should -Be 0
                $result.ErrorCount | Should -Be 1
                $result.Actions[0].Status | Should -Be 'Failed'
                [IO.File]::Exists($file) | Should -BeTrue
            }
        )

        It 'rechecks eligibility twice around confirmation before removal' (
            {
                $null = New-ExecutionFixture
                Mock Test-RetentionExecutionCandidate -ModuleName RetentionEngine (
                    {
                        return 'Eligible'
                    }
                )
                Mock Remove-RetentionCandidate -ModuleName RetentionEngine (
                    {
                    }
                )
                $result = Invoke-RetentionCleanup $script:policy -Execute -Confirm:$false
                Should -Invoke Test-RetentionExecutionCandidate -ModuleName RetentionEngine -Times 2 -Exactly
                Should -Invoke Remove-RetentionCandidate -ModuleName RetentionEngine -Times 1 -Exactly
            }
        )

        It 'skips a candidate when the second fresh check changes its answer' (
            {
                $file = New-ExecutionFixture
                $state = [pscustomobject](
                    @{
                        Calls = 0
                    }
                )
                $check = (
                    {
                        $state.Calls++
                        if ($state.Calls -eq 1)
                        {
                            return 'Eligible'
                        }

                        return 'ChangedSinceScan'
                    }
                ).GetNewClosure()
                Mock Test-RetentionExecutionCandidate -ModuleName RetentionEngine -MockWith $check
                Mock Remove-RetentionCandidate -ModuleName RetentionEngine (
                    {
                        throw 'Changed file must not be removed.'
                    }
                )
                $result = Invoke-RetentionCleanup $script:policy -Execute -Confirm:$false
                $result.Status | Should -Be 'Partial'
                $result.Actions[0].Reason | Should -Be 'ChangedSinceScan'
                $result.DeletedCount | Should -Be 0
                [IO.File]::Exists($file) | Should -BeTrue
                Should -Invoke Remove-RetentionCandidate -ModuleName RetentionEngine -Times 0 -Exactly
            }
        )

        It 'rejects execution snapshots in the no-deletion HTML exporter' (
            {
                $null = New-ExecutionFixture
                $result = Invoke-RetentionCleanup $script:policy -Execute -WhatIf
                $destination = Join-Path (Split-Path $script:root) 'receipt.html'
                (
                    {
                        Export-RetentionReportHtml $result.ScanReport -LiteralPath $destination
                    }
                ) | Should -Throw '*report-only*'
            }
        )

        It 'detects actual metadata changes before a candidate is removed' (
            {
                $file = New-ExecutionFixture
                $scan = Get-RetentionReport $script:policy
                [IO.File]::WriteAllText($file, 'different content')
                $reason = & (Get-Module RetentionEngine) (
                    {
                        param($Candidate, $Scan)
                        Test-RetentionExecutionCandidate -Candidate $Candidate -ScanReport $Scan
                    }
                ) $scan.Candidates[0] $scan
                $reason | Should -Be 'ChangedSinceScan'
                [IO.File]::Exists($file) | Should -BeTrue
            }
        )

        It 'honours an ignore marker added after the scan, including an ancestor marker' (
            {
                $file = New-ExecutionFixture 'child/old.log'
                $scan = Get-RetentionReport $script:policy
                [IO.File]::WriteAllText((Join-Path $script:root 'ignore'), '')
                $reason = & (Get-Module RetentionEngine) (
                    {
                        param($Candidate, $Scan)
                        Test-RetentionExecutionCandidate -Candidate $Candidate -ScanReport $Scan
                    }
                ) $scan.Candidates[0] $scan
                $reason | Should -Be 'ProtectedByIgnoreMarker'
                [IO.File]::Exists($file) | Should -BeTrue
            }
        )

        It 'rejects a candidate outside its root during the fresh check' (
            {
                $null = New-ExecutionFixture
                $scan = Get-RetentionReport $script:policy
                $scan.Candidates[0].Path = Join-Path (Split-Path $script:root) 'outside.log'
                (
                    {
                        & (Get-Module RetentionEngine) (
                            {
                                param($Candidate, $Scan)
                                Test-RetentionExecutionCandidate -Candidate $Candidate -ScanReport $Scan
                            }
                        ) $scan.Candidates[0] $scan
                    }
                ) | Should -Throw '*outside*'
            }
        )

        It 'rejects a directory substituted for the file' (
            {
                $file = New-ExecutionFixture
                $scan = Get-RetentionReport $script:policy
                [IO.File]::Delete($file)
                [void][IO.Directory]::CreateDirectory($file)
                $reason = & (Get-Module RetentionEngine) (
                    {
                        param($Candidate, $Scan)
                        Test-RetentionExecutionCandidate -Candidate $Candidate -ScanReport $Scan
                    }
                ) $scan.Candidates[0] $scan
                $reason | Should -Be 'EntryTypeChanged'
            }
        )
    }
)
