function ConvertTo-RetentionHtmlTable
{
    param([object[]]$Rows, [string[]]$Properties, [string[]]$Labels, [string]$EmptyText)
    if ($Rows.Count -eq 0)
    {
        return '<p class="empty">' + (ConvertTo-RetentionHtmlText $EmptyText) + '</p>'
    }

    $html = [Text.StringBuilder]::new('<div class="table-wrap"><table><thead><tr>')
    foreach ($label in $Labels)
    {
        [void]$html.Append('<th scope="col">').Append((ConvertTo-RetentionHtmlText $label)).Append('</th>')
    }

    [void]$html.Append('</tr></thead><tbody>')
    foreach ($row in $Rows)
    {
        [void]$html.Append('<tr>')
        foreach ($property in $Properties)
        {
            [void]$html.Append('<td>').Append((ConvertTo-RetentionHtmlText $row.$property)).Append('</td>')
        }

        [void]$html.Append('</tr>')
    }

    [void]$html.Append('</tbody></table></div>')
    return $html.ToString()
}
