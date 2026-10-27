BeforeAll (
    {
        Import-Module (Join-Path $PSScriptRoot '../src/RetentionEngine/RetentionEngine.psd1') -Force
    }
)

Describe 'SQL Server job discovery' (
    {
        It 'returns configured job names and typed rule counts without running cleanup' (
            {
                Mock Invoke-RetentionSqlQuery -ModuleName RetentionEngine (
                    {
                        [pscustomobject](
                            @{
                                JobName = 'FinanceExports'
                                RuleCount = 3
                                EnabledRuleCount = 2
                            }
                        )
                        [pscustomobject](
                            @{
                                JobName = 'PausedLogs'
                                RuleCount = 1
                                EnabledRuleCount = 0
                            }
                        )
                    }
                )
                Mock Invoke-RetentionCleanup -ModuleName RetentionEngine (
                    {
                        throw 'Discovery must not run cleanup.'
                    }
                )
                $jobs = @(Get-RetentionJob -ServerInstance 'SQL01' -Database 'Automation')
                $jobs.Count | Should -Be 2
                $jobs[0].JobName | Should -Be 'FinanceExports'
                $jobs[0].RuleCount | Should -BeOfType ([long])
                $jobs[1].EnabledRuleCount | Should -Be 0
                Should -Invoke Invoke-RetentionSqlQuery -ModuleName RetentionEngine -Times 1 -Exactly -ParameterFilter (
                    {
                        $ServerInstance -eq 'SQL01' -and $Database -eq 'Automation' -and
                        $Query -match 'GROUP BY JobName' -and $Query -notmatch 'HAVING' -and
                        $Query -notmatch '\b(UPDATE|INSERT|DELETE|EXEC)\b'
                    }
                )
                Should -Invoke Invoke-RetentionCleanup -ModuleName RetentionEngine -Times 0 -Exactly
            }
        )

        It 'filters enabled jobs with a fixed HAVING clause only when requested' (
            {
                Mock Invoke-RetentionSqlQuery -ModuleName RetentionEngine (
                    {
                        return @()
                    }
                )
                $null = Get-RetentionJob -ServerInstance 'SQL01' -Database 'Automation' -EnabledOnly
                Should -Invoke Invoke-RetentionSqlQuery -ModuleName RetentionEngine -Times 1 -Exactly -ParameterFilter (
                    {
                        $Query -match 'HAVING SUM\(CONVERT\(bigint, Enabled\)\) > 0' -and $Query -match 'ORDER BY JobName;'
                    }
                )
            }
        )

        It 'returns no jobs for an empty result, without inventing a default job' (
            {
                Mock Invoke-RetentionSqlQuery -ModuleName RetentionEngine (
                    {
                        return @()
                    }
                )
                @(Get-RetentionJob -ServerInstance 'SQL01' -Database 'Automation').Count | Should -Be 0
            }
        )

        It 'propagates database failures rather than presenting an empty list' (
            {
                Mock Invoke-RetentionSqlQuery -ModuleName RetentionEngine (
                    {
                        throw 'Database unavailable.'
                    }
                )
                (
                    {
                        Get-RetentionJob -ServerInstance 'SQL01' -Database 'Automation'
                    }
                ) | Should -Throw '*Database unavailable*'
            }
        )

        It 'rejects blank connection settings before issuing a query' (
            {
                Mock Invoke-RetentionSqlQuery -ModuleName RetentionEngine (
                    {
                        throw 'No query expected.'
                    }
                )
                (
                    {
                        Get-RetentionJob -ServerInstance ' ' -Database 'Automation'
                    }
                ) | Should -Throw '*must not be blank*'
                Should -Invoke Invoke-RetentionSqlQuery -ModuleName RetentionEngine -Times 0 -Exactly
            }
        )

        It 'builds an integrated, encrypted connection and safely quotes server settings' (
            {
                $server = 'SQL01;Integrated Security=false'
                $connectionString = & (Get-Module RetentionEngine) (
                    {
                        param($Server)
                        New-RetentionSqlConnectionString -ServerInstance $Server -Database 'Automation'
                    }
                ) $server
                $builder = [System.Data.Common.DbConnectionStringBuilder]::new()
                $builder.set_ConnectionString($connectionString)
                $builder['Data Source'] | Should -Be $server
                [string]$builder['Integrated Security'] | Should -Be 'True'
                [string]$builder['Encrypt'] | Should -Be 'True'
                [string]$builder['TrustServerCertificate'] | Should -Be 'False'
                [string]$builder['Connect Timeout'] | Should -Be '15'
                $builder.ContainsKey('Password') | Should -BeFalse
                $builder.ContainsKey('User ID') | Should -BeFalse
            }
        )

        It 'rejects an actual database call on non-Windows hosts' -Skip:$IsWindows (
            {
                (
                    {
                        & (Get-Module RetentionEngine) (
                            {
                                Invoke-RetentionSqlQuery -ServerInstance 'SQL01' -Database 'Automation' -Query 'SELECT 1;'
                            }
                        )
                    }
                ) | Should -Throw '*Windows only*'
            }
        )
    }
)
