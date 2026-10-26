# Contributing

## Code style

Use four spaces for each indentation level. Do not use tab characters. Opening and closing braces belong on their own lines, including one-statement blocks and PowerShell hashtable literals (`@{`). Prefer named parameters, clear variable names and one statement per line over aliases, compressed expressions or clever shortcuts.

PowerShell command arguments cannot generally start a scriptblock on a new line without explicit continuation. Use a parenthesised argument rather than a trailing backtick; for example:

```powershell
BeforeAll (
    {
        Import-Module ./src/RetentionEngine/RetentionEngine.psd1 -Force
    }
)
```

Code inside literal HTML/CSS strings follows that format's syntax rather than being rewritten as PowerShell blocks. The untouched legacy script is preserved as historical code; style checks cover rebuilt sources, tests, examples and tools.

Run `./tools/Test-SourceStyle.ps1` and the Pester acceptance suite before committing. The style checker also verifies PowerShell syntax. Tests must target disposable fixtures, never real cleanup paths. Tests involving deletion must opt in explicitly and must not treat a preview as proof of a real deletion.
