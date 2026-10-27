BeforeAll (
    {
        Import-Module (Join-Path $PSScriptRoot '../src/RetentionEngine/RetentionEngine.psd1') -Force
        if (-not ('RetentionEngineTests.SqlTestConnection' -as [type]))
        {
            Add-Type -Path (Join-Path $PSScriptRoot 'Support/SqlTestConnection.cs')
        }
    }
)

Describe 'Self-contained SQL queries' (
    {
        BeforeEach (
            {
                InModuleScope RetentionEngine (
                    {
                        $script:sqlFixture = [RetentionEngineTests.SqlTestConnection]::new()
                        Mock New-RetentionSqlConnection (
                            {
                                return $script:sqlFixture
                            }
                        )
                    }
                )
            }
        )

        It 'reads typed values and nulls, then releases reader, command and connection' (
            {
                InModuleScope RetentionEngine (
                    {
                        $table = $script:sqlFixture.Command.Table
                        $null = $table.Columns.Add('JobName', [string])
                        $null = $table.Columns.Add('RuleCount', [long])
                        $null = $table.Rows.Add('FinanceExports', [long]3)
                        $null = $table.Rows.Add([DBNull]::Value, [long]0)
                        $rows = @(Invoke-RetentionSqlQuery -ServerInstance 'SQL01' -Database 'Automation' -Query 'SELECT JobName, RuleCount;')
                        $rows.Count | Should -Be 2
                        $rows[0].JobName | Should -Be 'FinanceExports'
                        $rows[0].RuleCount | Should -BeOfType ([long])
                        ($null -eq $rows[1].JobName) | Should -BeTrue
                        $script:sqlFixture.Command.CommandText | Should -Be 'SELECT JobName, RuleCount;'
                        $script:sqlFixture.Command.CommandTimeout | Should -Be 30
                        $script:sqlFixture.Command.Reader.IsClosed | Should -BeTrue
                        $script:sqlFixture.Command.Disposed | Should -BeTrue
                        $script:sqlFixture.Disposed | Should -BeTrue
                        $script:sqlFixture.Opened | Should -BeFalse
                    }
                )
            }
        )

        It 'returns no objects for an empty result and still releases all resources' (
            {
                InModuleScope RetentionEngine (
                    {
                        $null = $script:sqlFixture.Command.Table.Columns.Add('JobName', [string])
                        @(Invoke-RetentionSqlQuery -ServerInstance 'SQL01' -Database 'Automation' -Query 'SELECT JobName;').Count | Should -Be 0
                        $script:sqlFixture.Command.Reader.IsClosed | Should -BeTrue
                        $script:sqlFixture.Command.Disposed | Should -BeTrue
                        $script:sqlFixture.Disposed | Should -BeTrue
                    }
                )
            }
        )

        It 'releases the connection and propagates a failed login' (
            {
                InModuleScope RetentionEngine (
                    {
                        $script:sqlFixture.FailOpen = $true
                        (
                            {
                                Invoke-RetentionSqlQuery -ServerInstance 'SQL01' -Database 'Automation' -Query 'SELECT 1;'
                            }
                        ) | Should -Throw '*Login failed*'
                        $script:sqlFixture.Disposed | Should -BeTrue
                    }
                )
            }
        )

        It 'releases the connection if command creation fails' (
            {
                InModuleScope RetentionEngine (
                    {
                        $script:sqlFixture.FailCreateCommand = $true
                        (
                            {
                                Invoke-RetentionSqlQuery -ServerInstance 'SQL01' -Database 'Automation' -Query 'SELECT 1;'
                            }
                        ) | Should -Throw '*Cannot create command*'
                        $script:sqlFixture.Disposed | Should -BeTrue
                    }
                )
            }
        )

        It 'releases command and connection and propagates query failures' (
            {
                InModuleScope RetentionEngine (
                    {
                        $script:sqlFixture.Command.FailExecute = $true
                        (
                            {
                                Invoke-RetentionSqlQuery -ServerInstance 'SQL01' -Database 'Automation' -Query 'SELECT 1;'
                            }
                        ) | Should -Throw '*Query failed*'
                        $script:sqlFixture.Command.Disposed | Should -BeTrue
                        $script:sqlFixture.Disposed | Should -BeTrue
                    }
                )
            }
        )

        It 'releases the connection even if command disposal fails' (
            {
                InModuleScope RetentionEngine (
                    {
                        $script:sqlFixture.Command.FailDispose = $true
                        (
                            {
                                Invoke-RetentionSqlQuery -ServerInstance 'SQL01' -Database 'Automation' -Query 'SELECT 1;'
                            }
                        ) | Should -Throw '*Command disposal failed*'
                        $script:sqlFixture.Command.Reader.IsClosed | Should -BeTrue
                        $script:sqlFixture.Disposed | Should -BeTrue
                    }
                )
            }
        )

        It 'passes SQL credentials through discovery without putting them in the connection string' (
            {
                $credential = [pscredential]::new('cleanup_reader', (ConvertTo-SecureString 'fixture-only' -AsPlainText -Force))
                Mock Invoke-RetentionSqlQuery -ModuleName RetentionEngine (
                    {
                        return @()
                    }
                )
                $null = Get-RetentionJob -ServerInstance 'SQL01' -Database 'Automation' -Credential $credential
                Should -Invoke Invoke-RetentionSqlQuery -ModuleName RetentionEngine -Times 1 -Exactly -ParameterFilter (
                    {
                        $Credential.UserName -eq 'cleanup_reader'
                    }
                )
                $text = & (Get-Module RetentionEngine) (
                    {
                        New-RetentionSqlConnectionString -ServerInstance 'SQL01' -Database 'Automation' -SqlAuthentication
                    }
                )
                $builder = [System.Data.Common.DbConnectionStringBuilder]::new()
                $builder.set_ConnectionString($text)
                [string]$builder['Integrated Security'] | Should -Be 'False'
                [string]$builder['Encrypt'] | Should -Be 'True'
                $builder.ContainsKey('Password') | Should -BeFalse
                $builder.ContainsKey('User ID') | Should -BeFalse
            }
        )
    }
)

Describe 'Runtime SQL client construction on Windows' (
    {
        It 'constructs an integrated connection without requiring a SQL PowerShell module' -Skip:(-not $IsWindows) (
            {
                & (Get-Module RetentionEngine) (
                    {
                        $connection = New-RetentionSqlConnection -ServerInstance 'SQL01' -Database 'Automation'
                        try
                        {
                            $connection | Should -BeOfType ([System.Data.SqlClient.SqlConnection])
                            $connection.State | Should -Be ([System.Data.ConnectionState]::Closed)
                            $connection.Credential | Should -BeNullOrEmpty
                            $connection.ConnectionTimeout | Should -Be 15
                        }
                        finally
                        {
                            $connection.Dispose()
                        }
                    }
                )
            }
        )

        It 'constructs SQL authentication with a secure credential and no password in its connection string' -Skip:(-not $IsWindows) (
            {
                & (Get-Module RetentionEngine) (
                    {
                        $password = ConvertTo-SecureString 'fixture-only' -AsPlainText -Force
                        $credential = [pscredential]::new('cleanup_reader', $password)
                        $connection = New-RetentionSqlConnection -ServerInstance 'SQL01' -Database 'Automation' -Credential $credential
                        try
                        {
                            $connection.Credential.UserId | Should -Be 'cleanup_reader'
                            $connection.Credential.Password.IsReadOnly() | Should -BeTrue
                            $connection.ConnectionString | Should -Not -Match 'fixture-only|cleanup_reader'
                            $connection.ConnectionString | Should -Match 'integrated security=False'
                        }
                        finally
                        {
                            $connection.Dispose()
                        }
                    }
                )
            }
        )
    }
)
