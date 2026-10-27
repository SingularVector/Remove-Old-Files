BeforeAll (
    {
        Import-Module (Join-Path $PSScriptRoot '../src/RetentionEngine/RetentionEngine.psd1') -Force

        function New-SqlJobFixtureRule
        {
            param([string]$Root)

            $null = [IO.Directory]::CreateDirectory($Root)
            $path = Join-Path $Root 'old.log'
            [IO.File]::WriteAllText($path, 'disposable SQL job fixture')
            [IO.File]::SetLastWriteTimeUtc($path, [datetime]::UtcNow.AddDays(-60))

            return [pscustomobject](
                @{
                    RuleId            = [guid]::NewGuid()
                    JobName           = 'LabLogs'
                    CleanupPath       = $Root
                    FileExtension     = 'log'
                    RetentionDays     = 30
                    IncludeSubfolders = $true
                    Enabled           = $true
                }
            )
        }
    }
)

Describe 'SQL-backed sequential cleanup jobs' (
    {
        BeforeEach (
            {
                $script:root = Join-Path $TestDrive ([guid]::NewGuid().ToString())

                if ($IsMacOS -and $script:root.StartsWith('/var/'))
                {
                    $script:root = '/private' + $script:root
                }

                $script:rows = @(
                    (New-SqlJobFixtureRule -Root (Join-Path $script:root 'first'))
                    (New-SqlJobFixtureRule -Root (Join-Path $script:root 'second'))
                )

                $script:jobParameters =
                @{
                    ServerInstance = 'SQL01'
                    Database       = 'AutomationLab'
                    JobName        = 'LabLogs'
                }

                $moduleParameters =
                @{
                    Rows = $script:rows
                }

                InModuleScope RetentionEngine -Parameters $moduleParameters (
                    {
                        param($Rows)

                        $script:sqlJobRows = $Rows
                        $script:sqlJobWrites = [Collections.Generic.List[object]]::new()
                        $script:sqlJobCanRecord = 1
                        $script:sqlJobWriteFailure = $false
                        $script:sqlJobMissingRow = $false

                        Mock Invoke-RetentionSqlQuery (
                            {
                                switch -Regex ($Query)
                                {
                                    '^SELECT RuleId'
                                    {
                                        return $script:sqlJobRows
                                    }
                                    '^SELECT CASE WHEN'
                                    {
                                        return [pscustomobject](
                                            @{
                                                CanRecordStatus = $script:sqlJobCanRecord
                                            }
                                        )
                                    }
                                    '^UPDATE dbo.CleanupRules'
                                    {
                                        $values =
                                        @{
                                        }

                                        foreach ($parameter in $Parameters)
                                        {
                                            $values[$parameter.Name] = $parameter.Value
                                        }

                                        $script:sqlJobWrites.Add($values)

                                        if ($script:sqlJobWriteFailure)
                                        {
                                            throw 'Status database unavailable.'
                                        }

                                        if ($script:sqlJobMissingRow)
                                        {
                                            return @()
                                        }

                                        return [pscustomobject](
                                            @{
                                                RuleId = $values['@RuleId']
                                            }
                                        )
                                    }
                                    default
                                    {
                                        throw "Unexpected SQL statement: $Query"
                                    }
                                }
                            }
                        )
                    }
                )
            }
        )

        It 'loads every enabled rule for a read-only plan and never records status' (
            {
                $job = Invoke-RetentionCleanup @jobParameters
                $job.Mode | Should -Be 'ReportOnly'
                $job.Status | Should -Be 'Completed'
                $job.ConfiguredRuleCount | Should -Be 2
                $job.ProcessedRuleCount | Should -Be 2
                $job.PlannedCount | Should -Be 2
                $job.DeletedCount | Should -Be 0
                @($job.Rules | Where-Object StatusRecorded).Count | Should -Be 0

                foreach ($row in $rows)
                {
                    [IO.File]::Exists((Join-Path $row.CleanupPath 'old.log')) | Should -BeTrue
                }

                Should -Invoke Invoke-RetentionSqlQuery -ModuleName RetentionEngine -Times 1 -Exactly
            }
        )

        It 'keeps both files and all database status unchanged under Execute WhatIf' (
            {
                $job = Invoke-RetentionCleanup @jobParameters -Execute -WhatIf
                $job.Mode | Should -Be 'WhatIf'
                $job.DeletedCount | Should -Be 0

                foreach ($row in $rows)
                {
                    [IO.File]::Exists((Join-Path $row.CleanupPath 'old.log')) | Should -BeTrue
                }

                Should -Invoke Invoke-RetentionSqlQuery -ModuleName RetentionEngine -Times 1 -Exactly
            }
        )

        It 'executes sequentially and records each original rule with UTC, exception bit and machine' (
            {
                $job = Invoke-RetentionCleanup @jobParameters -Execute -Confirm:$false
                $job.Status | Should -Be 'Completed'
                $job.DeletedCount | Should -Be 2
                $job.ErrorCount | Should -Be 0
                $job.UnattemptedRuleCount | Should -Be 0
                @($job.Rules | Where-Object StatusRecorded).Count | Should -Be 2

                InModuleScope RetentionEngine (
                    {
                        $script:sqlJobWrites.Count | Should -Be 2

                        for ($index = 0; $index -lt 2; $index++)
                        {
                            $write = $script:sqlJobWrites[$index]
                            $write['@RuleId'] | Should -Be $script:sqlJobRows[$index].RuleId
                            $write['@HadExceptions'] | Should -BeFalse
                            $write['@MachineName'] | Should -Be ([Environment]::MachineName)
                            $write['@ExecutedAtUtc'].Kind | Should -Be ([DateTimeKind]::Utc)
                        }
                    }
                )
            }
        )

        It 'binds a quoted job name as data and forwards SQL credentials' (
            {
                $jobParameters.JobName = "Owner's logs'; --"
                $credential = [pscredential]::new('lab_reader', (ConvertTo-SecureString 'fixture-only' -AsPlainText -Force))
                $null = Invoke-RetentionCleanup @jobParameters -Credential $credential

                Should -Invoke Invoke-RetentionSqlQuery -ModuleName RetentionEngine -Times 1 -Exactly -ParameterFilter (
                    {
                        $Parameters[0].Name -eq '@JobName' -and
                        $Parameters[0].Value -eq "Owner's logs'; --" -and
                        $Query -notmatch "Owner" -and
                        $Credential.UserName -eq 'lab_reader'
                    }
                )
            }
        )

        It 'rejects a bad later rule before scanning or deleting the valid first rule' (
            {
                $rows[1].RetentionDays = -1

                Mock Get-RetentionReport -ModuleName RetentionEngine (
                    {
                        throw 'No scan expected.'
                    }
                )

                (
                    {
                        Invoke-RetentionCleanup @jobParameters -Execute -Confirm:$false
                    }
                ) | Should -Throw '*RetentionDays*'

                Should -Invoke Get-RetentionReport -ModuleName RetentionEngine -Times 0 -Exactly
                [IO.File]::Exists((Join-Path $rows[0].CleanupPath 'old.log')) | Should -BeTrue
            }
        )

        It 'blocks overlapping roots before any cleanup' (
            {
                $rows[1].CleanupPath = Join-Path $rows[0].CleanupPath 'nested'

                (
                    {
                        Invoke-RetentionCleanup @jobParameters -Execute -Confirm:$false
                    }
                ) | Should -Throw '*overlapping*'

                [IO.File]::Exists((Join-Path $rows[0].CleanupPath 'old.log')) | Should -BeTrue
                Should -Invoke Invoke-RetentionSqlQuery -ModuleName RetentionEngine -Times 1 -Exactly
            }
        )

        It 'does not execute or record disabled rules' (
            {
                $rows[0].Enabled = $false
                $job = Invoke-RetentionCleanup @jobParameters -Execute -Confirm:$false
                $job.ConfiguredRuleCount | Should -Be 2
                $job.EnabledRuleCount | Should -Be 1
                $job.DeletedCount | Should -Be 1
                $job.Rules[0].RuleId | Should -Be $rows[1].RuleId
                [IO.File]::Exists((Join-Path $rows[0].CleanupPath 'old.log')) | Should -BeTrue
            }
        )

        It 'returns Disabled for a configured job with no enabled rules and makes no writes' (
            {
                $rows[0].Enabled = $false
                $rows[1].Enabled = $false
                $job = Invoke-RetentionCleanup @jobParameters -Execute -Confirm:$false
                $job.Status | Should -Be 'Disabled'
                $job.Rules.Count | Should -Be 0
                Should -Invoke Invoke-RetentionSqlQuery -ModuleName RetentionEngine -Times 1 -Exactly
            }
        )

        It 'reports an unknown job as an error rather than an empty successful run' (
            {
                InModuleScope RetentionEngine (
                    {
                        $script:sqlJobRows = @()
                    }
                )

                (
                    {
                        Invoke-RetentionCleanup @jobParameters
                    }
                ) | Should -Throw '*No configured cleanup job*'
            }
        )

        It 'blocks deletion when status permissions are missing' (
            {
                InModuleScope RetentionEngine (
                    {
                        $script:sqlJobCanRecord = 0
                    }
                )

                (
                    {
                        Invoke-RetentionCleanup @jobParameters -Execute -Confirm:$false
                    }
                ) | Should -Throw '*cannot update*'

                foreach ($row in $rows)
                {
                    [IO.File]::Exists((Join-Path $row.CleanupPath 'old.log')) | Should -BeTrue
                }
            }
        )

        It 'records an inaccessible rule as an exception and proceeds with the independent rule' (
            {
                $rows[0].CleanupPath = Join-Path $script:root 'missing'
                $job = Invoke-RetentionCleanup @jobParameters -Execute -Confirm:$false
                $job.Status | Should -Be 'Partial'
                $job.Rules[0].Status | Should -Be 'Blocked'
                $job.Rules[0].HadExceptions | Should -BeTrue
                $job.DeletedCount | Should -Be 1

                InModuleScope RetentionEngine (
                    {
                        $script:sqlJobWrites[0]['@HadExceptions'] | Should -BeTrue
                        $script:sqlJobWrites[1]['@HadExceptions'] | Should -BeFalse
                    }
                )
            }
        )

        It 'retains read-only files, records their failure and continues independent cleanup' (
            {
                $readOnly = Join-Path $rows[0].CleanupPath 'old.log'
                [IO.File]::SetAttributes($readOnly, [IO.FileAttributes]::ReadOnly)

                try
                {
                    $job = Invoke-RetentionCleanup @jobParameters -Execute -Confirm:$false
                    $job.Status | Should -Be 'Partial'
                    $job.DeletedCount | Should -Be 1
                    $job.ErrorCount | Should -Be 1
                    $job.Rules[0].HadExceptions | Should -BeTrue
                    [IO.File]::Exists($readOnly) | Should -BeTrue
                }
                finally
                {
                    [IO.File]::SetAttributes($readOnly, [IO.FileAttributes]::Normal)
                }
            }
        )

        It 'stops before the next rule if the status database fails after deletion' (
            {
                InModuleScope RetentionEngine (
                    {
                        $script:sqlJobWriteFailure = $true
                    }
                )

                $job = Invoke-RetentionCleanup @jobParameters -Execute -Confirm:$false
                $job.Status | Should -Be 'Partial'
                $job.DeletedCount | Should -Be 1
                $job.ProcessedRuleCount | Should -Be 1
                $job.UnattemptedRuleCount | Should -Be 1
                $job.Rules[0].StatusRecorded | Should -BeFalse
                $job.Errors[0].Operation | Should -Be 'RecordRuleStatus'
                [IO.File]::Exists((Join-Path $rows[1].CleanupPath 'old.log')) | Should -BeTrue
            }
        )

        It 'does not recreate a rule that disappeared before status recording' (
            {
                InModuleScope RetentionEngine (
                    {
                        $script:sqlJobMissingRow = $true
                    }
                )

                $job = Invoke-RetentionCleanup @jobParameters -Execute -Confirm:$false
                $job.UnattemptedRuleCount | Should -Be 1
                $job.Errors[0].Message | Should -Match 'removed or reassigned'
            }
        )

        It 'records successful attempts even when there were zero eligible files' (
            {
                foreach ($row in $rows)
                {
                    [IO.File]::SetLastWriteTimeUtc((Join-Path $row.CleanupPath 'old.log'), [datetime]::UtcNow)
                }

                $job = Invoke-RetentionCleanup @jobParameters -Execute -Confirm:$false
                $job.Status | Should -Be 'Completed'
                $job.DeletedCount | Should -Be 0
                @($job.Rules | Where-Object StatusRecorded).Count | Should -Be 2
                @($job.Rules | Where-Object HadExceptions).Count | Should -Be 0
            }
        )
    }
)
