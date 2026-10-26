function Write-RetentionHtmlFile
{
    param([string]$Destination, [string]$Content, [bool]$Overwrite)
    # Write completely before replacing the destination. Never follow a destination link for writes.
    $temporary = Join-Path ([IO.Path]::GetDirectoryName($Destination)) ('.retention-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try
    {
        $stream = [IO.FileStream]::new($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try
        {
            $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Content)
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush()
        }

        finally
        {
            $stream.Dispose()
        }

        [IO.File]::Move($temporary, $Destination, $Overwrite)
    }

    finally
    {
        if ([IO.File]::Exists($temporary))
        {
            [IO.File]::Delete($temporary)
        }
    }
}
