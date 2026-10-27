function Get-RetentionFile
{
    param([string]$LiteralPath)
    $item = Get-Item -LiteralPath $LiteralPath -Force -ErrorAction Stop
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint))
    {
        throw [IO.IOException]::new('Entry changed type during inspection.')
    }

    if (-not $IsWindows -and $item.UnixStat.ItemType.ToString() -ne 'File')
    {
        return $null
    }

    [pscustomobject](
        @{
            Length           = [long]$item.Length
            LastWriteTimeUtc = $item.LastWriteTimeUtc
        }
    )
}
