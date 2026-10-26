BeforeAll (
    {
        Import-Module (Join-Path $PSScriptRoot '../src/RetentionEngine/RetentionEngine.psd1') -Force
        function New-FixtureFile
        {
            param([string]$Name, [datetime]$Timestamp = $script:oldTime)
            $path = Join-Path $script:root $Name
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
            [IO.File]::WriteAllText($path, 'fixture')
            [IO.File]::SetLastWriteTimeUtc($path, $Timestamp)
            return $path
        }

        $script:now = [datetimeoffset]'2026-10-26T12:00:00Z'
        $script:oldTime = $script:now.UtcDateTime.AddDays(-31)
    }
)

Describe 'Get-RetentionReport report-only contract' (
    {
        BeforeEach (
            {
                $script:root = Join-Path (Join-Path $TestDrive ([guid]::NewGuid().ToString())) 'scope'
                # macOS exposes /var through a symlink; use its physical spelling for fixtures.
                if ($IsMacOS -and $script:root.StartsWith('/var/'))
                {
                    $script:root = '/private' + $script:root
                }

                if ($IsMacOS -and $script:root.StartsWith('/tmp/'))
                {
                    $script:root = '/private' + $script:root
                }

                [void][IO.Directory]::CreateDirectory($script:root)
                $script:policy = (
                    @{
                        PolicyId = 'test-logs'
                        RootPath = $script:root
                        FilePattern = '*.log'
                        RetentionDays = 30
                        Recurse = $true
                        Enabled = $true
                    }
                )
            }
        )

        It 'selects only matching files strictly older than one fixed cutoff' (
            {
                $null = New-FixtureFile 'old.log'
                $null = New-FixtureFile 'boundary.log' $script:now.UtcDateTime.AddDays(-30)
                $null = New-FixtureFile 'new.log' $script:now.UtcDateTime.AddDays(-1)
                $null = New-FixtureFile 'future.log' $script:now.UtcDateTime.AddDays(1)
                $null = New-FixtureFile 'old.txt'
                $r = Get-RetentionReport $script:policy -EvaluationTimeUtc $script:now
                $r.Status | Should -Be 'Completed'
                $r.CandidateCount | Should -Be 1
                [IO.Path]::GetFileName($r.Candidates[0].Path) | Should -Be 'old.log'
                $r.CandidateBytes | Should -Be 7
                $r.InspectedFileCount | Should -Be 5
                $r.ExcludedFileCount | Should -Be 4
                $r.CutoffUtc | Should -Be $script:now.UtcDateTime.AddDays(-30)
                @($r.Exclusions | Where-Object Reason -EQ 'NotOldEnough').Count | Should -Be 3
                $r.Candidates[0].LastWriteTimeUtc.Kind | Should -Be 'Utc'
                $r.Candidates[0].Length | Should -BeOfType ([long])
                $r.EffectivePolicy.Recurse | Should -BeOfType ([bool])
            }
        )

        It 'completes an empty scope without failure and emits one result' (
            {
                $results = @(Get-RetentionReport $script:policy -EvaluationTimeUtc $script:now)
                $results.Count | Should -Be 1
                $results[0].Status | Should -Be 'Completed'
                $results[0].Candidates.Count | Should -Be 0
                $results[0].ErrorCount | Should -Be 0
            }
        )

        It 'honours recursion instead of treating a false value as enabled' (
            {
                $null = New-FixtureFile 'child/nested.log'
                $script:policy.Recurse = $false
                $r = Get-RetentionReport $script:policy -EvaluationTimeUtc $script:now
                $r.CandidateCount | Should -Be 0
                $r.ExcludedDirectoryCount | Should -Be 1
                $r.Exclusions[0].Reason | Should -Be 'RecursionDisabled'
                $script:policy.Recurse = $true
                (Get-RetentionReport $script:policy -EvaluationTimeUtc $script:now).CandidateCount | Should -Be 1
            }
        )

        It 'protects an entire subtree without confusing sibling directory prefixes' (
            {
                $null = New-FixtureFile 'Archive/ignore'
                $null = New-FixtureFile 'Archive/old.log'
                $null = New-FixtureFile 'Archive/deep/old.log'
                $null = New-FixtureFile 'ArchiveOld/keep-inspecting.log'
                Mock Get-RetentionChildren -ModuleName RetentionEngine (
                    {
                        throw 'Protected descendants must not be visited.'
                    }
                ) -ParameterFilter (
                    {
                        [IO.Path]::GetFileName($LiteralPath) -eq 'deep'
                    }
                )
                $r = Get-RetentionReport $script:policy -EvaluationTimeUtc $script:now
                $r.Status | Should -Be 'Completed'
                $r.CandidateCount | Should -Be 1
                $r.InspectedFileCount | Should -Be 1
                $r.ExcludedDirectoryCount | Should -Be 1
                $r.Exclusions[0].Reason | Should -Be 'IgnoreMarker'
                Should -Invoke Get-RetentionChildren -ModuleName RetentionEngine -Times 0 -Exactly -ParameterFilter (
                    {
                        [IO.Path]::GetFileName($LiteralPath) -eq 'deep'
                    }
                )
            }
        )

        It 'excludes the whole root when its marker exists' (
            {
                $null = New-FixtureFile 'ignore'
                $null = New-FixtureFile 'old.log'
                $r = Get-RetentionReport $script:policy -EvaluationTimeUtc $script:now
                $r.Status | Should -Be 'Completed'
                $r.CandidateCount | Should -Be 0
                $r.InspectedFileCount | Should -Be 0
                $r.Exclusions[0].Path | Should -Be $script:root
            }
        )

        It 'does not treat a directory named ignore as a marker file' (
            {
                $null = New-FixtureFile 'ignore/old.log'
                (Get-RetentionReport $script:policy -EvaluationTimeUtc $script:now).CandidateCount | Should -Be 1
            }
        )

        It 'includes hidden files and applies documented platform filename case rules' (
            {
                $null = New-FixtureFile '.hidden.log'
                $null = New-FixtureFile 'upper.LOG'
                $r = Get-RetentionReport $script:policy -EvaluationTimeUtc $script:now
                $r.CandidateCount | Should -Be $(if ($IsWindows)
                    {
                        2
                    }
                    else
                    {
                        1
                    }
                )
            }
        )

        It 'applies the same case rule to ignore markers' (
            {
                $null = New-FixtureFile 'IGNORE'
                $null = New-FixtureFile 'old.log'
                $r = Get-RetentionReport $script:policy -EvaluationTimeUtc $script:now
                $r.CandidateCount | Should -Be $(if ($IsWindows)
                    {
                        0
                    }
                    else
                    {
                        1
                    }
                )
            }
        )

        It 'interprets question marks and literal filenames without provider wildcard expansion' (
            {
                $null = New-FixtureFile 'a.log'
                $null = New-FixtureFile 'ab.log'
                $script:policy.FilePattern = '?.log'
                $r = Get-RetentionReport $script:policy -EvaluationTimeUtc $script:now
                $r.CandidateCount | Should -Be 1
                $bracketRoot = Join-Path $script:root '[literal]'
                [void][IO.Directory]::CreateDirectory($bracketRoot)
                [IO.File]::WriteAllText((Join-Path $bracketRoot 'a.log'), 'test')
                [IO.File]::SetLastWriteTimeUtc((Join-Path $bracketRoot 'a.log'), $script:oldTime)
                $script:policy.RootPath = $bracketRoot
                (Get-RetentionReport $script:policy -EvaluationTimeUtc $script:now).CandidateCount | Should -Be 1
            }
        )

        It 'returns Disabled without inspecting an unavailable root' (
            {
                $script:policy.Enabled = $false
                $script:policy.RootPath = Join-Path $script:root 'missing'
                Mock Get-RetentionAttributes -ModuleName RetentionEngine (
                    {
                        throw 'Must not access filesystem.'
                    }
                )
                Mock Get-RetentionChildren -ModuleName RetentionEngine (
                    {
                        throw 'Must not enumerate.'
                    }
                )
                $r = Get-RetentionReport $script:policy -EvaluationTimeUtc $script:now
                $r.Status | Should -Be 'Disabled'
                $r.ErrorCount | Should -Be 0
                Should -Invoke Get-RetentionAttributes -ModuleName RetentionEngine -Times 0 -Exactly
                Should -Invoke Get-RetentionChildren -ModuleName RetentionEngine -Times 0 -Exactly
            }
        )

        It 'rejects an invalid <Field> without traversing' -TestCases @(
            (
                @{
                    Field = 'Recurse'
                    Value = '0'
                }
            ), (
                @{
                    Field = 'Enabled'
                    Value = 1
                }
            ),
            (
                @{
                    Field = 'RetentionDays'
                    Value = '30'
                }
            ), (
                @{
                    Field = 'RetentionDays'
                    Value = 1.5
                }
            ),
            (
                @{
                    Field = 'RetentionDays'
                    Value = 0
                }
            ), (
                @{
                    Field = 'RetentionDays'
                    Value = -1
                }
            ),
            (
                @{
                    Field = 'RetentionDays'
                    Value = 36501
                }
            ), (
                @{
                    Field = 'PolicyId'
                    Value = ''
                }
            ),
            (
                @{
                    Field = 'FilePattern'
                    Value = ''
                }
            ), (
                @{
                    Field = 'FilePattern'
                    Value = '../*.log'
                }
            ),
            (
                @{
                    Field = 'FilePattern'
                    Value = '[ab].log'
                }
            ), (
                @{
                    Field = 'RootPath'
                    Value = 'relative/path'
                }
            ),
            (
                @{
                    Field = 'RootPath'
                    Value = 'Env:PATH'
                }
            )
        ) (
            {
                param($Field, $Value)
                $script:policy[$Field] = $Value
                Mock Get-RetentionAttributes -ModuleName RetentionEngine (
                    {
                        throw 'Must not access filesystem.'
                    }
                )
                $r = Get-RetentionReport $script:policy -EvaluationTimeUtc $script:now
                $r.Status | Should -Be 'Failed'
                $r.Errors[0].Operation | Should -Be 'ValidatePolicy'
                Should -Invoke Get-RetentionAttributes -ModuleName RetentionEngine -Times 0 -Exactly
            }
        )

        It 'rejects parent traversal before normalisation can hide a linked ancestor' (
            {
                $script:policy.RootPath = Join-Path $script:root '../scope'
                $r = Get-RetentionReport $script:policy
                $r.Status | Should -Be 'Failed'
                $r.Errors[0].Operation | Should -Be 'ValidatePolicy'
            }
        )

        It 'treats shell expansion characters as literal filename characters' (
            {
                $null = New-FixtureFile 'cash$.log'
                $script:policy.FilePattern = 'cash$.log'
                (Get-RetentionReport $script:policy -EvaluationTimeUtc $script:now).CandidateCount | Should -Be 1
            }
        )

        It 'supports an all-filenames pattern including extensionless files' (
            {
                $null = New-FixtureFile 'extensionless'
                $script:policy.FilePattern = '*'
                (Get-RetentionReport $script:policy -EvaluationTimeUtc $script:now).CandidateCount | Should -Be 1
            }
        )

        It 'classifies a nonregular entry as excluded, not as a candidate' (
            {
                $null = New-FixtureFile 'special.log'
                Mock Get-RetentionFile -ModuleName RetentionEngine (
                    {
                        return $null
                    }
                )
                $r = Get-RetentionReport $script:policy -EvaluationTimeUtc $script:now
                $r.Status | Should -Be 'Completed'
                $r.CandidateCount | Should -Be 0
                $r.Exclusions[0].Reason | Should -Be 'NotRegularFile'
                $r.InspectedFileCount | Should -Be 0
            }
        )

        It 'rejects Windows device and alternate-stream roots' -Skip:(-not $IsWindows) (
            {
                foreach ($path in '\\?\C:\logs', '\\.\C:\logs', 'C:\logs:stream')
                {
                    $script:policy.RootPath = $path
                    (Get-RetentionReport $script:policy).Errors[0].Operation | Should -Be 'ValidatePolicy'
                }
            }
        )

        It 'rejects null and missing fields with structured validation failures' (
            {
                (Get-RetentionReport -Policy $null).Errors[0].Operation | Should -Be 'ValidatePolicy'
                $script:policy.Remove('Recurse')
                (Get-RetentionReport $script:policy).Errors[0].Message | Should -Match 'Recurse'
            }
        )

        It 'validates disabled policies and rejects filesystem roots' (
            {
                $script:policy.Enabled = $false
                $script:policy.RootPath = [IO.Path]::GetPathRoot($script:root)
                (Get-RetentionReport $script:policy).Status | Should -Be 'Failed'
            }
        )

        It 'rejects a cutoff outside the timestamp range' (
            {
                $r = Get-RetentionReport $script:policy -EvaluationTimeUtc ([datetimeoffset]::MinValue)
                $r.Status | Should -Be 'Failed'
                $r.Errors[0].Operation | Should -Be 'ValidatePolicy'
            }
        )

        It 'reports a missing root as failed rather than empty success' (
            {
                $script:policy.RootPath = Join-Path $script:root 'missing'
                $r = Get-RetentionReport $script:policy
                $r.Status | Should -Be 'Failed'
                $r.ErrorCount | Should -Be 1
                $r.Errors[0].Operation | Should -Be 'ValidateRoot'
            }
        )

        It 'rejects a file as the root' (
            {
                $script:policy.RootPath = New-FixtureFile 'not-a-directory.log'
                (Get-RetentionReport $script:policy).Status | Should -Be 'Failed'
            }
        )

        It 'marks root enumeration failure as Failed' (
            {
                Mock Get-RetentionChildren -ModuleName RetentionEngine (
                    {
                        throw [UnauthorizedAccessException]::new('Denied by fixture.')
                    }
                )
                $r = Get-RetentionReport $script:policy
                $r.Status | Should -Be 'Failed'
                $r.CandidateCount | Should -Be 0
                $r.Errors[0].Operation | Should -Be 'InspectDirectory'
            }
        )

        It 'retains accessible candidates and reports a child enumeration failure as Partial' (
            {
                $null = New-FixtureFile 'blocked/hidden.log'
                $null = New-FixtureFile 'ok.log'
                Mock Get-RetentionChildren -ModuleName RetentionEngine (
                    {
                        throw [UnauthorizedAccessException]::new('Denied by fixture.')
                    }
                ) -ParameterFilter (
                    {
                        [IO.Path]::GetFileName($LiteralPath) -eq 'blocked'
                    }
                )
                $r = Get-RetentionReport $script:policy -EvaluationTimeUtc $script:now
                $r.Status | Should -Be 'Partial'
                $r.CandidateCount | Should -Be 1
                $r.ErrorCount | Should -Be 1
            }
        )

        It 'does not scan a directory if its marker cannot be checked' (
            {
                $null = New-FixtureFile 'blocked/ignore'
                $null = New-FixtureFile 'blocked/do-not-select.log'
                $null = New-FixtureFile 'ok.log'
                Mock Get-RetentionAttributes -ModuleName RetentionEngine (
                    {
                        throw [UnauthorizedAccessException]::new('Cannot inspect marker.')
                    }
                ) -ParameterFilter (
                    {
                        [IO.Path]::GetFileName($LiteralPath) -eq 'ignore'
                    }
                )
                $r = Get-RetentionReport $script:policy -EvaluationTimeUtc $script:now
                $r.Status | Should -Be 'Partial'
                $r.CandidateCount | Should -Be 1
                $r.Errors[0].Operation | Should -Be 'InspectDirectory'
            }
        )

        It 'reports a metadata failure rather than making the file a candidate' (
            {
                $null = New-FixtureFile 'unreadable.log'
                Mock Get-RetentionFile -ModuleName RetentionEngine (
                    {
                        throw [IO.IOException]::new('Metadata unavailable.')
                    }
                )
                $r = Get-RetentionReport $script:policy -EvaluationTimeUtc $script:now
                $r.Status | Should -Be 'Partial'
                $r.CandidateCount | Should -Be 0
                $r.InspectedFileCount | Should -Be 0
                $r.ErrorCount | Should -Be 1
            }
        )

        It 'rejects inaccessible root ancestry before enumeration' (
            {
                Mock Get-RetentionAttributes -ModuleName RetentionEngine (
                    {
                        throw [UnauthorizedAccessException]::new('Ancestor denied.')
                    }
                ) -ParameterFilter (
                    {
                        [IO.Path]::GetFileName($LiteralPath) -eq 'scope'
                    }
                )
                $r = Get-RetentionReport $script:policy
                $r.Status | Should -Be 'Failed'
                $r.Errors[0].Operation | Should -Be 'ValidateRoot'
            }
        )

        It 'returns deterministic classifications without mutating caller policy or files' (
            {
                $a = New-FixtureFile 'z.log'
                $b = New-FixtureFile 'a.log'
                $before = $script:policy | ConvertTo-Json
                $hash = (Get-FileHash -LiteralPath $a).Hash
                $stamp = [IO.File]::GetLastWriteTimeUtc($a)
                $first = Get-RetentionReport ([pscustomobject]$script:policy) -EvaluationTimeUtc $script:now
                $second = Get-RetentionReport $script:policy -EvaluationTimeUtc $script:now
                ($first.Candidates | ConvertTo-Json) | Should -Be ($second.Candidates | ConvertTo-Json)
                $first.Candidates[0].Path | Should -Be $b
                $first.DeletedCount | Should -Be 0
                $first.RunId | Should -Not -Be $second.RunId
                $first.EndedAtUtc | Should -Not -BeNullOrEmpty
                ($script:policy | ConvertTo-Json) | Should -Be $before
                (Get-FileHash -LiteralPath $a).Hash | Should -Be $hash
                [IO.File]::GetLastWriteTimeUtc($a) | Should -Be $stamp
            }
        )

        It 'skips a real directory symbolic link, and rejects it as root or root ancestor' (
            {
                $target = Join-Path $script:root 'target'
                $null = New-FixtureFile 'target/old.log'
                $link = Join-Path $script:root 'linked'
                try
                {
                    $null = New-Item -ItemType SymbolicLink -Path $link -Target $target -ErrorAction Stop
                }

                catch
                {
                    Set-ItResult -Skipped -Because 'Symbolic-link creation unavailable on this host.'
                    return
                }

                $r = Get-RetentionReport $script:policy -EvaluationTimeUtc $script:now
                $r.Status | Should -Be 'Completed'
                $r.CandidateCount | Should -Be 1
                $r.SkippedLinkCount | Should -Be 1
                $script:policy.RootPath = $link
                (Get-RetentionReport $script:policy).Status | Should -Be 'Failed'
                $null = New-FixtureFile 'target/child/old.log'
                $script:policy.RootPath = Join-Path $link 'child'
                (Get-RetentionReport $script:policy).Status | Should -Be 'Failed'
            }
        )

        It 'skips a dangling symbolic link' (
            {
                $link = Join-Path $script:root 'broken.log'
                try
                {
                    $null = New-Item -ItemType SymbolicLink -Path $link -Target (Join-Path $script:root 'missing') -ErrorAction Stop
                }

                catch
                {
                    Set-ItResult -Skipped -Because 'Symbolic-link creation unavailable on this host.'
                    return
                }

                $r = Get-RetentionReport $script:policy -EvaluationTimeUtc $script:now
                $r.Status | Should -Be 'Completed'
                $r.SkippedLinkCount | Should -Be 1
                $r.CandidateCount | Should -Be 0
            }
        )

        It 'skips a Windows junction without traversing it' -Skip:(-not $IsWindows) (
            {
                $target = Join-Path $script:root 'target'
                $null = New-FixtureFile 'target/old.log'
                $null = New-Item -ItemType Junction -Path (Join-Path $script:root 'junction') -Target $target
                $r = Get-RetentionReport $script:policy -EvaluationTimeUtc $script:now
                $r.CandidateCount | Should -Be 1
                $r.SkippedLinkCount | Should -Be 1
            }
        )

        It 'validates UNC behaviour on a provisioned Windows share' -Skip (
            {
                # Requires a controlled share and execution identity; not covered by local fixtures.
            }
        )
    }
)
