BeforeAll (
    {
        Import-Module (Join-Path $PSScriptRoot '../src/RetentionEngine/RetentionEngine.psd1') -Force
    }
)

Describe 'Creating SQL cleanup policies' (
    {
        BeforeEach (
            {
                $script:settings = (
                    @{
                        ServerInstance = 'SQL01'
                        Database       = 'Automation'
                        JobName        = 'AppLogs'
                        CleanupPath    = 'D:\Logs'
                        FileExtension  = 'log'
                        RetentionDays  = 30
                    }
                )
                Mock Invoke-RetentionSqlQuery -ModuleName RetentionEngine (
                    {
                        [pscustomobject](
                            @{
                                RuleId            = [guid]'0e3db0b5-617e-43f7-b357-019bc7865c22'
                                JobName           = 'AppLogs'
                                LastExecutedAtUtc = $null
                                LastHadExceptions = $null
                                LastMachineName   = $null
                            }
                        )
                    }
                )
            }
        )

        It 'inserts a parameterised rule and returns its database-generated identity' (
            {
                $rule = New-RetentionPolicy @settings -IncludeSubfolders
                $rule.RuleId | Should -Be ([guid]'0e3db0b5-617e-43f7-b357-019bc7865c22')
                $rule.LastExecutedAtUtc | Should -BeNullOrEmpty
                Should -Invoke Invoke-RetentionSqlQuery -ModuleName RetentionEngine -Times 1 -Exactly -ParameterFilter (
                    {
                        $Query -match 'INSERT INTO dbo.CleanupRules' -and
                        $Query -match 'OUTPUT INSERTED.\*' -and
                        $Query -notmatch 'AppLogs|D:\\Logs|LastExecutedAtUtc|LastHadExceptions|LastMachineName' -and
                        $Parameters.Count -eq 6 -and
                        $Parameters[0].Value -eq 'AppLogs' -and
                        $Parameters[1].Value -eq 'D:\Logs' -and
                        $Parameters[2].Value -eq 'log' -and
                        $Parameters[3].Value -eq 30 -and
                        $Parameters[4].Value -eq $true -and
                        $Parameters[5].Value -eq $true
                    }
                )
            }
        )

        It 'does not connect or insert when WhatIf is specified' (
            {
                @(New-RetentionPolicy @settings -WhatIf).Count | Should -Be 0
                Should -Invoke Invoke-RetentionSqlQuery -ModuleName RetentionEngine -Times 0 -Exactly
            }
        )

        It 'supports an explicit all-file rule and disabled creation without recursion' (
            {
                $settings.FileExtension = ''
                $null = New-RetentionPolicy @settings -Disabled
                Should -Invoke Invoke-RetentionSqlQuery -ModuleName RetentionEngine -Times 1 -Exactly -ParameterFilter (
                    {
                        $Parameters[2].Value -eq '' -and
                        $Parameters[4].Value -eq $false -and
                        $Parameters[5].Value -eq $false
                    }
                )
            }
        )

        It 'keeps quotes in a job name as data and forwards an optional SQL credential' (
            {
                $settings.JobName = "Owner's logs'; --"
                $credential = [pscredential]::new('cleanup_writer', (ConvertTo-SecureString 'fixture-only' -AsPlainText -Force))
                $null = New-RetentionPolicy @settings -Credential $credential
                Should -Invoke Invoke-RetentionSqlQuery -ModuleName RetentionEngine -Times 1 -Exactly -ParameterFilter (
                    {
                        $Parameters[0].Value -eq "Owner's logs'; --" -and
                        $Query -notmatch "Owner" -and
                        $Credential.UserName -eq 'cleanup_writer'
                    }
                )
            }
        )

        It 'accepts an explicit directory below a UNC share without accessing its filesystem' (
            {
                $settings.CleanupPath = '\\fileserver\archive\exports'
                $null = New-RetentionPolicy @settings
                Should -Invoke Invoke-RetentionSqlQuery -ModuleName RetentionEngine -Times 1 -Exactly -ParameterFilter (
                    {
                        $Parameters[1].Value -eq '\\fileserver\archive\exports'
                    }
                )
            }
        )

        It 'rejects unsafe or ambiguous paths before any database access: <Path>' -ForEach @(
            @{
                Path = 'D:\'
            }
            @{
                Path = '\\server\share'
            }
            @{
                Path = 'D:\Logs\.'
            }
            @{
                Path = 'D:\Logs\.. '
            }
            @{
                Path = 'logs'
            }
            @{
                Path = 'D:\Logs\..\Other'
            }
            @{
                Path = '\\?\D:\Logs'
            }
            @{
                Path = 'D:\Logs:stream'
            }
            @{
                Path = 'D:\Logs\*'
            }
        ) (
            {
                $settings.CleanupPath = $Path
                (
                    {
                        New-RetentionPolicy @settings
                    }
                ) | Should -Throw
                Should -Invoke Invoke-RetentionSqlQuery -ModuleName RetentionEngine -Times 0 -Exactly
            }
        )

        It 'rejects invalid extension, retention and blank settings even during preview' (
            {
                $settings.FileExtension = '*.log'
                (
                    {
                        New-RetentionPolicy @settings -WhatIf
                    }
                ) | Should -Throw
                $settings.FileExtension = 'log'
                $settings.RetentionDays = 0
                (
                    {
                        New-RetentionPolicy @settings -WhatIf
                    }
                ) | Should -Throw
                $settings.RetentionDays = 30
                $settings.JobName = ' '
                (
                    {
                        New-RetentionPolicy @settings -WhatIf
                    }
                ) | Should -Throw '*must not be blank*'
                Should -Invoke Invoke-RetentionSqlQuery -ModuleName RetentionEngine -Times 0 -Exactly
            }
        )

        It 'propagates database failure without pretending that a rule was saved' (
            {
                Mock Invoke-RetentionSqlQuery -ModuleName RetentionEngine (
                    {
                        throw 'INSERT denied.'
                    }
                )
                (
                    {
                        New-RetentionPolicy @settings
                    }
                ) | Should -Throw '*INSERT denied*'
            }
        )
    }
)
