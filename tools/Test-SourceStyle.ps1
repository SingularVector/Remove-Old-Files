#Requires -Version 7.4
[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path $PSScriptRoot)
)

$violations = [Collections.Generic.List[string]]::new()

foreach ($directory in '.', 'src', 'tests', 'tools')
{
    $path = Join-Path $RepositoryRoot $directory

    # Include the root scheduled-job launcher without scanning .git or dependencies twice.
    $files = if ($directory -eq '.')
    {
        Get-ChildItem -LiteralPath $path -File
    }
    else
    {
        Get-ChildItem -LiteralPath $path -Recurse -File
    }

    foreach ($file in $files)
    {
        if ($file.Extension -notin '.ps1', '.psm1', '.psd1')
        {
            continue
        }

        $text = [IO.File]::ReadAllText($file.FullName)
        $lines = $text -split '\r?\n'
        for ($index = 0; $index -lt $lines.Count; $index++)
        {
            $line = $lines[$index]
            if ($line.Contains("`t"))
            {
                $violations.Add("$($file.Name):$($index + 1): tabs are not allowed.")
            }
            $spaces = $line.Length - $line.TrimStart(' ').Length
            if ($spaces % 4 -ne 0)
            {
                $violations.Add("$($file.Name):$($index + 1): indentation must use four-space increments.")
            }
        }

        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$parseErrors)
        foreach ($parseError in $parseErrors)
        {
            $violations.Add("$($file.Name): $($parseError.Message)")
        }
        $isHashtable =
        {
            param($node)
            $node -is [Management.Automation.Language.HashtableAst]
        }
        $tables = $ast.FindAll($isHashtable, $true)
        foreach ($table in $tables)
        {
            if ($table.KeyValuePairs.Count -lt 2)
            {
                continue
            }
            $columns = [Collections.Generic.List[int]]::new()
            foreach ($pair in $table.KeyValuePairs)
            {
                foreach ($token in $tokens)
                {
                    if ($token.Kind -eq 'Equals' -and
                        $token.Extent.StartOffset -ge $pair.Item1.Extent.EndOffset -and
                        $token.Extent.EndOffset -le $pair.Item2.Extent.StartOffset)
                    {
                        $columns.Add($token.Extent.StartColumnNumber)
                        break
                    }
                }
            }
            if (@($columns | Select-Object -Unique).Count -gt 1)
            {
                $violations.Add("$($file.Name):$($table.Extent.StartLineNumber): align hashtable assignment operators.")
            }
        }
        foreach ($token in $tokens)
        {
            if ($token.Kind -in 'LCurly', 'AtCurly', 'RCurly')
            {
                if ($lines[$token.Extent.StartLineNumber - 1].Trim() -ne $token.Text)
                {
                    $violations.Add("$($file.Name):$($token.Extent.StartLineNumber): brace must be on its own line.")
                }
            }
        }
    }
}

if ($violations.Count -gt 0)
{
    throw ($violations -join [Environment]::NewLine)
}
Write-Output 'Source style passed: brace-only lines, spaces only, four-space indentation, aligned hashtables and valid syntax.'
