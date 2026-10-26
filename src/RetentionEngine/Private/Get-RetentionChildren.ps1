function Get-RetentionChildren
{
    param([string]$LiteralPath)
    [System.IO.Directory]::GetFileSystemEntries($LiteralPath)
}
