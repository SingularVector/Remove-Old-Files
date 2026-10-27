BeforeAll (
    {
        $script:generator = Join-Path $PSScriptRoot '../examples/New-RetentionTestData.ps1'
        Import-Module (Join-Path $PSScriptRoot '../src/RetentionEngine/RetentionEngine.psd1') -Force
    }
)

Describe 'Disposable VM lab fixtures' (
    {
        BeforeEach (
            {
                $script:labPath = Join-Path $TestDrive ('lab-' + [guid]::NewGuid())
                if ($IsMacOS -and $script:labPath.StartsWith('/var/'))
                {
                    $script:labPath = '/private' + $script:labPath
                }
            }
        )

        It 'round-trips saved policies and matches the fixed-time inventory and legacy CSV' (
            {
                $created = & $script:generator -LiteralPath $script:labPath -EvaluationTimeUtc '2026-10-27T12:00:00Z'
                $lab = Import-Clixml -LiteralPath (Join-Path $created.LabPath 'lab.clixml')
                $lab.Inventory.Count | Should -Be 14
                foreach ($row in $lab.Inventory)
                {
                    [IO.File]::Exists($row.Path) | Should -BeTrue
                    [IO.File]::GetLastWriteTimeUtc($row.Path) | Should -Be ([datetime]::Parse($row.LastWriteTimeUtc).ToUniversalTime())
                }
                if ($IsWindows)
                {
                    $hidden = [IO.File]::GetAttributes((Join-Path $lab.DataPath '.hidden-old.log'))
                    [bool]($hidden -band [IO.FileAttributes]::Hidden) | Should -BeTrue
                }
                $report = Get-RetentionReport -Policy $lab.Policy -EvaluationTimeUtc $lab.EvaluationTimeUtc
                $report.Status | Should -Be 'Completed'
                $report.CandidateCount | Should -Be $lab.ExpectedMainCandidateCount
                $expected = @($lab.Inventory | Where-Object (
                        {
                            $_.Scope -eq 'Main' -and $_.ExpectedAtReferenceTime -eq 'Candidate'
                        }
                    ) | Select-Object -ExpandProperty Path | Sort-Object)
                $actual = @($report.Candidates.Path | Sort-Object)
                ($actual -join '|') | Should -Be ($expected -join '|')
                $boundary = Get-RetentionReport -Policy $lab.BoundaryPolicy -EvaluationTimeUtc $lab.EvaluationTimeUtc
                $boundary.Status | Should -Be 'Completed'
                $boundary.CandidateCount | Should -Be $lab.ExpectedBoundaryCandidateCount
                [IO.Path]::GetFileName($boundary.Candidates[0].Path) | Should -Be 'before-cutoff.log'
                $batch = Get-RetentionBatchReport -LiteralPath (Join-Path $lab.LabPath 'FilePaths.csv') -EvaluationTimeUtc $lab.EvaluationTimeUtc
                $batch.Status | Should -Be 'Completed'
                $batch.Reports[0].CandidateCount | Should -Be 4
            }
        )

        It 'keeps previews unchanged and accounts for four deletions including the hidden log' (
            {
                $lab = & $script:generator -LiteralPath $script:labPath
                $plan = Invoke-RetentionCleanup -Policy $lab.Policy
                $plan.PlannedCount | Should -Be 4
                $preview = Invoke-RetentionCleanup -Policy $lab.Policy -Execute -WhatIf
                $preview.DeletedCount | Should -Be 0
                foreach ($row in $lab.Inventory)
                {
                    [IO.File]::Exists($row.Path) | Should -BeTrue
                }
                $result = Invoke-RetentionCleanup -Policy $lab.Policy -Execute -Confirm:$false
                $result.Status | Should -Be 'Completed'
                $result.DeletedCount | Should -Be $lab.ExpectedMainDeletedCount
                $result.ErrorCount | Should -Be $lab.ExpectedMainErrorCount
                foreach ($row in $lab.Inventory)
                {
                    $shouldRemain = $row.ExpectedOnExecution -ne 'Deleted'
                    [IO.File]::Exists($row.Path) | Should -Be $shouldRemain
                }
                $failed = @($result.Actions | Where-Object Status -EQ 'Failed')
                $failed.Count | Should -Be 0
                [IO.File]::Exists((Join-Path $lab.LabPath 'lab.clixml')) | Should -BeTrue
            }
        )

        It 'creates nothing under WhatIf and refuses to overwrite an existing lab' (
            {
                $null = & $script:generator -LiteralPath $script:labPath -WhatIf
                [IO.Directory]::Exists($script:labPath) | Should -BeFalse
                $lab = & $script:generator -LiteralPath $script:labPath
                $sentinel = Join-Path $lab.LabPath 'keep.txt'
                [IO.File]::WriteAllText($sentinel, 'existing content')
                (
                    {
                        & $script:generator -LiteralPath $script:labPath
                    }
                ) | Should -Throw '*already exists*'
                [IO.File]::ReadAllText($sentinel) | Should -Be 'existing content'
            }
        )
    }
)
