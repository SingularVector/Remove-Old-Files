# Contributing

## Code style

Use four spaces for each indentation level. Do not use tab characters. Opening and closing braces belong on their own lines, including one-statement blocks and PowerShell hashtable literals (`@{`). Align the assignment operators within each hashtable, including splats and object literals. Prefer switch when choosing among several cases; keep simple guard conditions as if statements. Use supported SQL libraries rather than deprecated providers. Prefer named parameters, clear variable names and one statement per line over aliases, compressed expressions or clever shortcuts.

Separate logical statements and control blocks with blank lines. Add breathing room after guard clauses, before loops and conditionals, between setup phases, and before returned or output objects. Keep hashtable entries together; avoid uninterrupted runs of assignments and method calls.

Comment the code sufficiently for another engineer to follow its intent. Explain the purpose of each logical phase, important assumptions, validation and safety boundaries, and non-obvious behaviour or failure cases. Keep comments close to the relevant code and update them when behaviour changes. Public functions should retain useful comment-based help and examples; avoid comments that merely repeat an obvious assignment.

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


## Module boundaries

Put one supported command per file under `src/RetentionEngine/Public` and one support function per file under `Private`. Keep the explicit loader lists, exported command list and manifest FileList in sync. Public names/parameters are the compatibility surface; internal changes must continue to pass the behavioural tests. Run the package tests before committing layout changes.


## Supported deployment scope

Target Windows, PowerShell 7.4+ and SQL Server with integrated authentication by default or an optional SQL credential. Do not add Unix/PostgreSQL support, worker assignment, leases or orchestration without an explicit new requirement. Keep database configuration as a single rules table, and preserve the difference between mocked query tests and live SQL Server verification.
