BeforeAll (
    {
        Import-Module (Join-Path $PSScriptRoot '../src/RetentionEngine/RetentionEngine.psd1') -Force
    }
)

Describe 'Export-RetentionReportHtml' (
    {
        BeforeEach (
            {
                $base = Join-Path $TestDrive ([guid]::NewGuid().ToString())
                if ($IsMacOS -and ($base.StartsWith('/var/') -or $base.StartsWith('/tmp/')))
                {
                    $base = '/private' + $base
                }

                $script:scanRoot = Join-Path $base 'scanned'
                $script:outputRoot = Join-Path $base 'reports'
                [void][IO.Directory]::CreateDirectory($script:scanRoot)
                [void][IO.Directory]::CreateDirectory($script:outputRoot)
                $script:destination = Join-Path $script:outputRoot 'report.html'
                $script:policy = [pscustomobject](
                    @{
                        PolicyId      = 'test-html'
                        RootPath      = $script:scanRoot
                        FilePattern   = '*.log'
                        RetentionDays = 30
                        Recurse       = $true
                        Enabled       = $true
                    }
                )
                $script:report = Get-RetentionReport $script:policy -EvaluationTimeUtc ([datetimeoffset]'2026-10-26T12:00:00Z')
            }
        )

        It 'writes one standalone UTF-8 HTML file with embedded CSS and no external resources' (
            {
                $output = @(Export-RetentionReportHtml $script:report -LiteralPath $script:destination)
                $output.Count | Should -Be 1
                $output[0].Path | Should -Be $script:destination
                $html = [IO.File]::ReadAllText($script:destination)
                $html | Should -Match '<!doctype html>'
                $html | Should -Match '<style>'
                $html | Should -Match 'Report only — no files deleted\.'
                $html | Should -Match 'Potential space reclaimable'
                $html | Should -Match 'Policy &amp; scope'
                $html | Should -Not -Match '(?i)<script|<link|<iframe|<img|https?://|url\('
                $html | Should -Match 'Content-Security-Policy'
                $html | Should -Match '2026-10-26 12:00:00'
            }
        )

        It 'renders candidates and protected paths while omitting routine skips without changing scan data' (
            {
                $file = Join-Path $script:scanRoot 'old.log'
                [IO.File]::WriteAllText($file, 'sample')
                [IO.File]::SetLastWriteTimeUtc($file, [datetime]'2026-09-01T00:00:00Z')
                [IO.File]::WriteAllText((Join-Path $script:scanRoot 'recent.txt'), 'other')
                $recent = Join-Path $script:scanRoot 'recent.log'
                [IO.File]::WriteAllText($recent, 'recent fixture')
                [IO.File]::SetLastWriteTimeUtc($recent, [datetime]'2026-10-25T00:00:00Z')
                $protected = Join-Path $script:scanRoot 'protected'
                $null = [IO.Directory]::CreateDirectory($protected)
                [IO.File]::WriteAllText((Join-Path $protected 'ignore'), 'fixture marker')
                $script:report = Get-RetentionReport $script:policy -EvaluationTimeUtc ([datetimeoffset]'2026-10-26T12:00:00Z')
                $before = $script:report | ConvertTo-Json -Depth 8
                $null = Export-RetentionReportHtml $script:report -LiteralPath $script:destination
                $html = [IO.File]::ReadAllText($script:destination)
                $html | Should -Match 'old\.log'
                $html | Should -Not -Match 'PatternMismatch|NotOldEnough|recent\.txt|recent\.log'
                $html | Should -Match 'IgnoreMarker'
                $html | Should -Match 'protected'
                $html | Should -Match '2026-09-01 00:00:00'
                ($script:report | ConvertTo-Json -Depth 8) | Should -Be $before
                [IO.File]::ReadAllText($file) | Should -Be 'sample'
                [IO.File]::GetLastWriteTimeUtc($file) | Should -Be ([datetimeoffset]'2026-09-01T00:00:00Z').UtcDateTime
            }
        )

        It 'keeps HTML bounded for thousands of routine skips while preserving totals and review exclusions' (
            {
                $exclusions = [Collections.Generic.List[object]]::new()

                for ($index = 1; $index -le 1000; $index++)
                {
                    $exclusions.Add([pscustomobject](
                            @{
                                Path   = Join-Path $script:scanRoot ("recent-$index.log")
                                Kind   = 'File'
                                Reason = 'NotOldEnough'
                            }
                        ))

                    $exclusions.Add([pscustomobject](
                            @{
                                Path   = Join-Path $script:scanRoot ("other-$index.txt")
                                Kind   = 'File'
                                Reason = 'PatternMismatch'
                            }
                        ))
                }

                foreach ($definition in @(
                        @('protected', 'Directory', 'IgnoreMarker'),
                        @('archive-link', 'Link', 'LinkOrReparsePoint'),
                        @('nested', 'Directory', 'RecursionDisabled')
                    ))
                {
                    $exclusions.Add([pscustomobject](
                            @{
                                Path   = Join-Path $script:scanRoot $definition[0]
                                Kind   = $definition[1]
                                Reason = $definition[2]
                            }
                        ))
                }

                $script:report.Exclusions = $exclusions.ToArray()
                $script:report.ExcludedEntryCount = 2003
                $script:report.ExcludedFileCount = 2000
                $script:report.ExcludedDirectoryCount = 2
                $script:report.SkippedLinkCount = 1
                $script:report.InspectedFileCount = 2000
                $before = $script:report | ConvertTo-Json -Depth 8

                $null = Export-RetentionReportHtml $script:report -LiteralPath $script:destination
                $html = [IO.File]::ReadAllText($script:destination)

                $html | Should -Not -Match 'NotOldEnough|PatternMismatch|recent-[0-9]+\.log|other-[0-9]+\.txt'
                foreach ($reason in 'IgnoreMarker', 'LinkOrReparsePoint', 'RecursionDisabled')
                {
                    $html | Should -Match $reason
                }
                $html | Should -Match '<strong>2003</strong>'
                $html.Length | Should -BeLessThan 25000
                ($script:report | ConvertTo-Json -Depth 8) | Should -Be $before
            }
        )

        It 'explains an empty review list when only routine skips were observed' (
            {
                $script:report.Exclusions = @(
                    [pscustomobject](
                        @{
                            Path   = Join-Path $script:scanRoot 'only-recent.log'
                            Kind   = 'File'
                            Reason = 'NotOldEnough'
                        }
                    )
                )

                $script:report.ExcludedEntryCount = 1
                $script:report.ExcludedFileCount = 1
                $script:report.InspectedFileCount = 1

                $null = Export-RetentionReportHtml $script:report -LiteralPath $script:destination
                $html = [IO.File]::ReadAllText($script:destination)

                $html | Should -Match 'No exclusions requiring individual review'
                $html | Should -Match 'totals still include those skips'
                $html | Should -Not -Match 'only-recent\.log|NotOldEnough'
            }
        )

        It 'makes a <Status> outcome explicit' -TestCases @(
            (
                @{
                    Status = 'Completed'
                    Text   = 'Inspection completed'
                }
            ),
            (
                @{
                    Status = 'Partial'
                    Text   = 'INCOMPLETE INSPECTION'
                }
            ),
            (
                @{
                    Status = 'Failed'
                    Text   = 'INSPECTION FAILED'
                }
            ),
            (
                @{
                    Status = 'Disabled'
                    Text   = 'POLICY DISABLED'
                }
            )
        ) (
            {
                param($Status, $Text)
                $script:report.Status = $Status
                $null = Export-RetentionReportHtml $script:report -LiteralPath $script:destination
                [IO.File]::ReadAllText($script:destination) | Should -Match $Text
            }
        )

        It 'escapes untrusted text in policy values, candidate paths, exclusions and errors' (
            {
                $attack = '<script>alert("x")</script>&'
                $script:report.PolicyId = $attack
                $script:report.EffectivePolicy.FilePattern = $attack
                $script:report.Status = 'Partial'
                $script:report.Candidates = @([pscustomobject](
                        @{
                            Path             = $attack
                            Length           = 1
                            LastWriteTimeUtc = [datetime]::UtcNow
                            Reason           = $attack
                        }
                    ))
                $script:report.CandidateCount = 1
                $script:report.Exclusions = @([pscustomobject](
                        @{
                            Path   = $attack
                            Kind   = $attack
                            Reason = $attack
                        }
                    ))
                $script:report.ExcludedEntryCount = 1
                $script:report.Errors = @([pscustomobject](
                        @{
                            Path      = $attack
                            Operation = $attack
                            Category  = $attack
                            Message   = $attack
                        }
                    ))
                $script:report.ErrorCount = 1
                $null = Export-RetentionReportHtml $script:report -LiteralPath $script:destination
                $html = [IO.File]::ReadAllText($script:destination)
                $html | Should -Not -Match '<script>'
                $html | Should -Match '&lt;script&gt;'
                $html | Should -Match '&amp;'
                $html | Should -Match '&quot;'
            }
        )

        It 'exports a real validation-failure report with unavailable effective policy' (
            {
                $script:report = Get-RetentionReport -Policy $null
                $null = Export-RetentionReportHtml $script:report -LiteralPath $script:destination
                [IO.File]::ReadAllText($script:destination) | Should -Match 'Policy is required'
            }
        )

        It 'rejects malformed or inconsistent reports before creating output' (
            {
                (
                    {
                        Export-RetentionReportHtml ([pscustomobject](
                                @{
                                    Status = 'Completed'
                                }
                            )) -LiteralPath $script:destination
                    }
                ) | Should -Throw
                $script:report.CandidateCount = 2
                (
                    {
                        Export-RetentionReportHtml $script:report -LiteralPath $script:destination
                    }
                ) | Should -Throw
                [IO.File]::Exists($script:destination) | Should -BeFalse
            }
        )

        It 'rejects a modified status or a report claiming deletions' (
            {
                $script:report.Status = '<script>'
                (
                    {
                        Export-RetentionReportHtml $script:report -LiteralPath $script:destination
                    }
                ) | Should -Throw
                $script:report.Status = 'Completed'
                $script:report.DeletedCount = 1
                (
                    {
                        Export-RetentionReportHtml $script:report -LiteralPath $script:destination
                    }
                ) | Should -Throw
            }
        )

        It 'does not write into the scanned root or its children' (
            {
                foreach ($file in @((Join-Path $script:scanRoot 'report.html'), (Join-Path $script:scanRoot 'child/report.html')))
                {
                    (
                        {
                            Export-RetentionReportHtml $script:report -LiteralPath $file
                        }
                    ) | Should -Throw '*outside the scanned root*'
                }
            }
        )

        It 'allows a sibling directory with a similar name to the scanned root' (
            {
                $sibling = $script:scanRoot + '-reports'
                [void][IO.Directory]::CreateDirectory($sibling)
                $null = Export-RetentionReportHtml $script:report -LiteralPath (Join-Path $sibling 'report.html')
                [IO.File]::Exists((Join-Path $sibling 'report.html')) | Should -BeTrue
            }
        )

        It 'refuses existing files by default and replaces them only with Force' (
            {
                [IO.File]::WriteAllText($script:destination, 'original')
                (
                    {
                        Export-RetentionReportHtml $script:report -LiteralPath $script:destination
                    }
                ) | Should -Throw '*already exists*'
                [IO.File]::ReadAllText($script:destination) | Should -Be 'original'
                $null = Export-RetentionReportHtml $script:report -LiteralPath $script:destination -Force
                [IO.File]::ReadAllText($script:destination) | Should -Match '<!doctype html>'
                @(Get-ChildItem -LiteralPath $script:outputRoot -Force).Count | Should -Be 1
            }
        )

        It 'supports WhatIf without creating or replacing output' (
            {
                Export-RetentionReportHtml $script:report -LiteralPath $script:destination -WhatIf
                [IO.File]::Exists($script:destination) | Should -BeFalse
                [IO.File]::WriteAllText($script:destination, 'original')
                Export-RetentionReportHtml $script:report -LiteralPath $script:destination -Force -WhatIf
                [IO.File]::ReadAllText($script:destination) | Should -Be 'original'
            }
        )

        It 'rejects non-HTML destinations, missing parents and parent traversal' (
            {
                (
                    {
                        Export-RetentionReportHtml $script:report -LiteralPath (Join-Path $script:outputRoot 'file.txt')
                    }
                ) | Should -Throw
                (
                    {
                        Export-RetentionReportHtml $script:report -LiteralPath (Join-Path $script:outputRoot 'missing/report.html')
                    }
                ) | Should -Throw
                (
                    {
                        Export-RetentionReportHtml $script:report -LiteralPath (Join-Path $script:outputRoot '../reports/report.html')
                    }
                ) | Should -Throw '*parent traversal*'
            }
        )

        It 'resolves relative destinations from the PowerShell location' (
            {
                Push-Location $script:outputRoot
                try
                {
                    $null = Export-RetentionReportHtml $script:report -LiteralPath './relative.html'
                    [IO.File]::Exists((Join-Path $script:outputRoot 'relative.html')) | Should -BeTrue
                }

                finally
                {
                    Pop-Location
                }
            }
        )

        It 'does not follow destination or ancestor symlinks, even with Force' (
            {
                $target = Join-Path $script:outputRoot 'original.html'
                [IO.File]::WriteAllText($target, 'original')
                try
                {
                    $null = New-Item -ItemType SymbolicLink -Path $script:destination -Target $target -ErrorAction Stop
                }

                catch
                {
                    Set-ItResult -Skipped -Because 'Symbolic-link creation unavailable.'
                    return
                }

                (
                    {
                        Export-RetentionReportHtml $script:report -LiteralPath $script:destination -Force
                    }
                ) | Should -Throw
                [IO.File]::ReadAllText($target) | Should -Be 'original'
                $linkDirectory = Join-Path (Split-Path $script:outputRoot) 'linked-output'
                $null = New-Item -ItemType SymbolicLink -Path $linkDirectory -Target $script:outputRoot
                (
                    {
                        Export-RetentionReportHtml $script:report -LiteralPath (Join-Path $linkDirectory 'new.html')
                    }
                ) | Should -Throw
            }
        )

        It 'cleans temporary output and preserves a file that appears before replacement' (
            {
                [IO.File]::WriteAllText($script:destination, 'appeared-concurrently')
                Mock Get-RetentionAttributes -ModuleName RetentionEngine (
                    {
                        throw [IO.FileNotFoundException]::new('Simulated absent destination during validation.')
                    }
                ) -ParameterFilter (
                    {
                        [IO.Path]::GetFileName($LiteralPath) -eq 'report.html'
                    }
                )
                (
                    {
                        Export-RetentionReportHtml $script:report -LiteralPath $script:destination
                    }
                ) | Should -Throw
                [IO.File]::ReadAllText($script:destination) | Should -Be 'appeared-concurrently'
                @(Get-ChildItem -LiteralPath $script:outputRoot -Force).Count | Should -Be 1
            }
        )

        It 'escapes an optional display label' (
            {
                $null = Export-RetentionReportHtml $script:report -LiteralPath $script:destination -ReportLabel '<demo>&'
                $html = [IO.File]::ReadAllText($script:destination)
                $html | Should -Match '&lt;demo&gt;&amp;'
                $html | Should -Not -Match '<demo>'
            }
        )

        It 'blocks case-variant output inside the scan root on Windows and macOS' -Skip:(-not ($IsWindows -or $IsMacOS)) (
            {
                $caseVariant = $script:scanRoot.ToUpperInvariant()
                (
                    {
                        Export-RetentionReportHtml $script:report -LiteralPath (Join-Path $caseVariant 'report.html')
                    }
                ) | Should -Throw '*outside the scanned root*'
            }
        )

        It 'propagates an output-write failure without changing the scanned report' (
            {
                Mock Write-RetentionHtmlFile -ModuleName RetentionEngine (
                    {
                        throw [IO.IOException]::new('Output unavailable.')
                    }
                )
                (
                    {
                        Export-RetentionReportHtml $script:report -LiteralPath $script:destination
                    }
                ) | Should -Throw '*Output unavailable*'
                [IO.File]::Exists($script:destination) | Should -BeFalse
                $script:report.Status | Should -Be 'Completed'
            }
        )
    }
)
