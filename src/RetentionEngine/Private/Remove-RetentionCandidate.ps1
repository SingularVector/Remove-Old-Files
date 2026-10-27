function Remove-RetentionCandidate
{
    param([string]$LiteralPath)

    # Hidden logs are eligible under the scan contract. Force allows their removal,
    # but retain the previous refusal to delete read-only files. ACLs still apply.
    $attributes = [IO.File]::GetAttributes($LiteralPath)

    if ($attributes -band ([IO.FileAttributes]::Directory -bor [IO.FileAttributes]::ReparsePoint))
    {
        throw [IO.IOException]::new('The retention candidate is no longer a regular file.')
    }

    if ($attributes -band [IO.FileAttributes]::ReadOnly)
    {
        throw [UnauthorizedAccessException]::new('Read-only retention files are not removed.')
    }

    # The public command owns confirmation and the two fresh eligibility checks.
    Remove-Item -LiteralPath $LiteralPath -Force -ErrorAction Stop -Confirm:$false -WhatIf:$false
}
