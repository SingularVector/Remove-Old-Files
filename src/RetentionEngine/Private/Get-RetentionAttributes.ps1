function Get-RetentionAttributes
{
    param([string]$LiteralPath)
    [System.IO.File]::GetAttributes($LiteralPath)
}
