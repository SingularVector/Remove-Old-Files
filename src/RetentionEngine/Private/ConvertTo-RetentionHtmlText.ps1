function ConvertTo-RetentionHtmlText
{
    param([AllowNull()][object]$Value)
    if ($null -eq $Value)
    {
        return 'Not available'
    }

    if ($Value -is [datetime] -or $Value -is [datetimeoffset])
    {
        return [Net.WebUtility]::HtmlEncode($Value.ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss 'UTC'", [Globalization.CultureInfo]::InvariantCulture))
    }

    return [Net.WebUtility]::HtmlEncode([string]$Value)
}
