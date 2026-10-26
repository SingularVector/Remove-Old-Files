# Module structure and distribution

The repository contains the legacy Remove-OldFiles script and the rebuilt PowerShell script module, RetentionEngine. The original script remains unchanged. There is no compiled C# dependency: the public commands are advanced PowerShell functions with normal help, parameter binding and preview/confirmation support where applicable.

## Public commands

| Command | Responsibility |
| --- | --- |
| Get-RetentionReport | Inspect one policy and return its structured scan result. |
| Import-RetentionPolicyCsv | Convert and validate legacy CSV without scanning target directories. |
| Get-RetentionBatchReport | Gate the whole CSV import, then scan each accepted policy. Reporting only. |
| Export-RetentionReportHtml | Present a report-only scan as standalone HTML. |
| Invoke-RetentionCleanup | Plan by default; optionally execute one policy with fresh checks and ShouldProcess. |

Invoke-RetentionCleanup is the cleanup entry point. Callers should not dot-source support files or call the private removal function directly. Existing command names and parameters remain unchanged by this reorganisation.

## Layout

```text
src/RetentionEngine/
    RetentionEngine.psd1
    RetentionEngine.psm1
    Public/
        Get-RetentionReport.ps1
        Import-RetentionPolicyCsv.ps1
        Get-RetentionBatchReport.ps1
        Export-RetentionReportHtml.ps1
        Invoke-RetentionCleanup.ps1
    Private/
        Get-RetentionAttributes.ps1
        Get-RetentionChildren.ps1
        Get-RetentionFile.ps1
        ConvertTo-RetentionHtmlText.ps1
        ConvertTo-RetentionHtmlTable.ps1
        Write-RetentionHtmlFile.ps1
        Test-RetentionExecutionCandidate.ps1
        Remove-RetentionCandidate.ps1
```

Each file holds one function. The psm1 loads explicit private and public file lists in a reviewable order and exports only the five supported commands. The manifest repeats that public boundary and lists runtime files for packaging. Private means an implementation detail outside the supported command interface; it is not a security sandbox against code that deliberately accesses module internals.

Filesystem adapters remain private so Pester can inject failures without changing operating-system permissions. HTML encoding/writing is separate from scanning. Fresh eligibility and removal remain separate internals behind the public cleanup command's ShouldProcess boundary.

## Use from the source checkout

From the repository directory:

```powershell
Import-Module ./src/RetentionEngine/RetentionEngine.psd1 -Force
Get-Command -Module RetentionEngine
Get-Help Invoke-RetentionCleanup -Examples

$plan = Invoke-RetentionCleanup -Policy $policy
$preview = Invoke-RetentionCleanup -Policy $policy -Execute -WhatIf
```

The Policy object follows the [reporting contract](report-only-usage.md). An explicit Execute switch is still required for actual removal, as documented in [controlled cleanup](controlled-cleanup.md). Importing the module does not scan or delete files.

## Build a portable module directory

```powershell
./tools/Build-Module.ps1 -WhatIf
$package = ./tools/Build-Module.ps1
Import-Module $package.ManifestPath -Force
```

Default output is `artifacts/RetentionEngine/2.0.0/`, including the alpha prerelease metadata in the manifest. The directory contains the runtime module files and the repository license, not the legacy script, tests, credentials or local editorial material. Build output is ignored by Git. The version directory is not overwritten; choose a fresh DestinationPath if rebuilding the same development version.

The builder creates a local directory only. It does not publish to PowerShell Gallery, install globally, alter PSModulePath or contact target systems. A failed build can leave an incomplete output directory; it returns no successful package object. Review/remove that build artifact or choose a fresh destination before trying again.

To use it elsewhere, copy the complete RetentionEngine directory to a location you manage, then import its versioned manifest explicitly. For name-based import, place that directory under one of the target account's existing PSModulePath directories. Do not distribute an individual Public or Private file. Supported target runtimes require PowerShell 7.4 or later; Windows/Linux/network integration evidence is separate from the local package check.

## Logging boundary

The engine returns structured results; it does not load New-LogEntry automatically or bundle an older copy of it. A scheduled runner can record run identifiers, policies, warnings and outcomes using the current New-LogEntry function, without contaminating the result stream with log messages. Automatic logging integration remains future work and is not a prerequisite for importing the module.

## Verification

The existing scanner, importer, exporter and execution tests run against this layout. Additional tests verify the export list, private-helper visibility, manifest contents, WhatIf builds, overwrite refusal, and import/use of a copied package from a fresh PowerShell process outside the repository. The local suite passed 104 tests with 3 platform-dependent skips on macOS/PowerShell 7.6.7/Pester 5.7.1.

The source-style check still covers Public and Private files recursively, with brace-only lines and four-space indentation. No deletion semantics are intentionally changed in this refactor.
