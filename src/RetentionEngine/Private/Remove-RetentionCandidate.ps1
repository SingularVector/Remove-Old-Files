function Remove-RetentionCandidate
{
    param([string]$LiteralPath)

    # The public command owns confirmation and fresh eligibility checks.
    Remove-Item -LiteralPath $LiteralPath -ErrorAction Stop -Confirm:$false -WhatIf:$false
}
