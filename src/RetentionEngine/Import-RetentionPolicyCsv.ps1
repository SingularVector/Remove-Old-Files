function Import-RetentionPolicyCsv {
    <#
    .SYNOPSIS
    Validates legacy CSV policies without scanning their target directories.
    .DESCRIPTION
    Returns one import result with accepted policies, warnings, errors and overlap
    records. Any invalid row or overlapping scope blocks batch execution. Row IDs
    identify source records, not persistent identities across file edits/reordering.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$LiteralPath)

    $policies = [Collections.Generic.List[object]]::new()
    $warnings = [Collections.Generic.List[object]]::new()
    $errors = [Collections.Generic.List[object]]::new()
    $overlaps = [Collections.Generic.List[object]]::new()
    $result = [pscustomobject][ordered]@{
        Status = 'Invalid'; SourceFile = $null; RecordCount = 0
        Policies = @(); Warnings = @(); Errors = @(); Overlaps = @(); IsReady = $false
    }
    $parser = $null
    try {
        try {
            $provider = $null; $drive = $null
            $source = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($LiteralPath, [ref]$provider, [ref]$drive)
            if ($provider.Name -ne 'FileSystem') { throw [ArgumentException]::new('CSV source must use the filesystem provider.') }
            $result.SourceFile = $source
            $parser = [Microsoft.VisualBasic.FileIO.TextFieldParser]::new($source, [Text.UTF8Encoding]::new($false, $true), $true)
            $parser.TextFieldType = [Microsoft.VisualBasic.FileIO.FieldType]::Delimited
            $parser.SetDelimiters(',')
            $parser.HasFieldsEnclosedInQuotes = $true
            $parser.TrimWhiteSpace = $true
            if ($parser.EndOfData) { throw [ArgumentException]::new('CSV is empty; the four legacy headers are required.') }
            $headers = @($parser.ReadFields() | ForEach-Object { $_.Trim() })
            $required = @('CleanupPath', 'FileExtension', 'AgeTolerance', 'IncludeSubFolders')
            $mapping = @{}
            for ($i = 0; $i -lt $headers.Count; $i++) {
                if ($mapping.ContainsKey($headers[$i])) { throw [ArgumentException]::new("Duplicate CSV header: $($headers[$i]).") }
                if ($headers[$i] -notin $required) { throw [ArgumentException]::new("Unsupported CSV header: $($headers[$i]). Expected only the four legacy fields.") }
                $mapping[$headers[$i]] = $i
            }
            foreach ($name in $required) {
                if (-not $mapping.ContainsKey($name)) { throw [ArgumentException]::new("Missing required CSV header: $name.") }
            }
            $rowNumber = 1
            while (-not $parser.EndOfData) {
                $line = $parser.LineNumber
                $rowNumber++
                $fields = $parser.ReadFields()
                $result.RecordCount++
                try {
                    if ($fields.Count -ne 4) { throw [ArgumentException]::new('CSV row must contain exactly four fields, including explicit empty cells.') }
                    $row = @{}
                    foreach ($name in $required) { $row[$name] = $fields[$mapping[$name]].Trim() }
                    if ([string]::IsNullOrWhiteSpace($row.CleanupPath)) { throw [ArgumentException]::new('CleanupPath is required.') }
                    $pattern = '*'
                    if ($row.FileExtension.Length -gt 0) {
                        if ($row.FileExtension -notmatch '^[\p{L}\p{N}_-]+(?:\.[\p{L}\p{N}_-]+)*$') {
                            throw [ArgumentException]::new('FileExtension must be a bare extension such as log or tar.gz; wildcards and paths are not accepted.')
                        }
                        $pattern = '*.' + $row.FileExtension
                    }
                    $days = 90
                    if ($row.AgeTolerance.Length -gt 0 -and
                        ($row.AgeTolerance -notmatch '^[0-9]+$' -or -not [int]::TryParse($row.AgeTolerance, [ref]$days))) {
                        throw [ArgumentException]::new('AgeTolerance must be an integer from 1 to 36500, or empty for 90 days.')
                    }
                    if ($row.IncludeSubFolders -notin @('', '0', '1')) {
                        throw [ArgumentException]::new('IncludeSubFolders accepts only 0, 1 or empty.')
                    }
                    $policy = [pscustomobject]@{
                        PolicyId = 'csv-row-' + $rowNumber
                        RootPath = $row.CleanupPath; FilePattern = $pattern; RetentionDays = $days
                        Recurse = ($row.IncludeSubFolders -eq '1'); Enabled = $true
                        SourceFile = $source; SourceRow = $rowNumber; SourceLine = $line
                    }
                    # Reuse engine structural validation with a disabled copy: no target I/O.
                    $validationPolicy = [pscustomobject]@{
                        PolicyId = $policy.PolicyId; RootPath = $policy.RootPath; FilePattern = $pattern
                        RetentionDays = $days; Recurse = $policy.Recurse; Enabled = $false
                    }
                    $validation = Get-RetentionReport -Policy $validationPolicy
                    if ($validation.Status -ne 'Disabled') { throw [ArgumentException]::new($validation.Errors[0].Message) }
                    $policy.RootPath = $validation.NormalizedRoot
                    $policies.Add($policy)
                    foreach ($pair in @(
                        @('FileExtension', $row.FileExtension, 'Empty extension explicitly matches all filenames, including extensionless files.'),
                        @('AgeTolerance', $row.AgeTolerance, 'Empty retention defaults to 90 days.'),
                        @('IncludeSubFolders', $row.IncludeSubFolders, 'Empty recursion defaults to false.')
                    )) {
                        if ($pair[1].Length -eq 0) {
                            $warnings.Add([pscustomobject]@{ SourceRow = $rowNumber; Field = $pair[0]; Message = $pair[2] })
                        }
                    }
                }
                catch {
                    $errors.Add([pscustomobject]@{ Scope = 'Row'; SourceRow = $rowNumber; SourceLine = $line; Message = $_.Exception.Message })
                }
            }
            if ($result.RecordCount -eq 0) { throw [ArgumentException]::new('CSV has headers but no policy records.') }
            # Conservative first contract: equal or nested roots conflict even if patterns differ.
            $comparison = if ($IsWindows -or $IsMacOS) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
            for ($i = 0; $i -lt $policies.Count; $i++) {
                for ($j = $i + 1; $j -lt $policies.Count; $j++) {
                    $left = $policies[$i]; $right = $policies[$j]
                    $same = $left.RootPath.Equals($right.RootPath, $comparison)
                    $nested = $left.RootPath.StartsWith($right.RootPath + [IO.Path]::DirectorySeparatorChar, $comparison) -or
                        $right.RootPath.StartsWith($left.RootPath + [IO.Path]::DirectorySeparatorChar, $comparison)
                    if ($same -or $nested) {
                        $overlaps.Add([pscustomobject]@{
                            LeftPolicyId = $left.PolicyId; RightPolicyId = $right.PolicyId
                            LeftRow = $left.SourceRow; RightRow = $right.SourceRow
                            Reason = $(if ($same) { 'SameRoot' } else { 'NestedRoots' })
                        })
                    }
                }
            }
            if ($errors.Count -eq 0 -and $overlaps.Count -eq 0) { $result.Status = 'Ready'; $result.IsReady = $true }
        }
        catch {
            $errors.Add([pscustomobject]@{ Scope = 'File'; SourceRow = $null; SourceLine = $(if ($parser) { $parser.ErrorLineNumber } else { $null }); Message = $_.Exception.Message })
        }
        return $result
    }
    finally {
        if ($null -ne $parser) { $parser.Dispose() }
        $result.Policies = $policies.ToArray()
        $result.Warnings = $warnings.ToArray()
        $result.Errors = $errors.ToArray()
        $result.Overlaps = $overlaps.ToArray()
    }
}

function Get-RetentionBatchReport {
    <#
    .SYNOPSIS
    Validates the entire legacy CSV before scanning any policy, then reports each.
    .DESCRIPTION
    Invalid rows, malformed files and overlapping roots block the entire batch.
    Runtime scan failures retain other reports and make the batch Partial or Failed.
    No files are deleted. Export individual Reports with Export-RetentionReportHtml.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$LiteralPath,
        [datetimeoffset]$EvaluationTimeUtc = [datetimeoffset]::UtcNow
    )
    $import = Import-RetentionPolicyCsv -LiteralPath $LiteralPath
    $reports = [Collections.Generic.List[object]]::new()
    $status = 'Failed'
    if ($import.IsReady) {
        foreach ($policy in $import.Policies) {
            $reports.Add((Get-RetentionReport -Policy $policy -EvaluationTimeUtc $EvaluationTimeUtc))
        }
        $successful = @($reports | Where-Object Status -EQ 'Completed').Count
        $partial = @($reports | Where-Object Status -EQ 'Partial').Count
        $status = if ($successful -eq $reports.Count) { 'Completed' }
            elseif ($successful -gt 0 -or $partial -gt 0) { 'Partial' } else { 'Failed' }
    }
    [pscustomobject][ordered]@{
        Status = $status; Mode = 'ReportOnly'; EvaluationTimeUtc = $EvaluationTimeUtc.UtcDateTime
        Import = $import; Reports = $reports.ToArray(); PolicyCount = $import.Policies.Count
        ReportCount = $reports.Count; DeletedCount = 0
    }
}
