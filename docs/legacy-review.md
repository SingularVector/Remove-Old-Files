# Legacy cleanup implementation: review notes

Reviewed source: the existing `Remove-OldFiles.ps1` and `FilePaths.csv` in this repository. These are static findings against the current checkout; the legacy script was not executed. They do not establish which exact revision or local customisation ran historically.

## Findings to address in the rebuild

| Area | Observed implementation | Consequence and response |
| --- | --- | --- |
| Logging interface | Call sites use `-LogName`, while the embedded `New-LogEntry` declares `LogFilePath` without that alias. | The checked-in caller/helper interfaces do not agree. Do not reuse the embedded helper blindly; keep engine results separate from logging. |
| Recursion conversion | Every nonempty `IncludeSubFolders` cell sets `$recursiveSearch` to 1. | A documented `0` can broaden traversal. Require actual Boolean policy fields and test false explicitly. |
| Ignore-marker scope | Recursive enumeration happens before exclusion, and candidates are compared to exact parent-directory names. | A marker does not protect all descendants as described. Prune protected subtrees before visiting their contents. |
| Exclusion state | `$skippedFolders` is assigned when markers exist, but not reset for every policy path. | State from one path can leak into later iterations. Each report-only run holds its own collections and policy state. |
| Deletion accounting | `Remove-Item` is inside try/catch without `-ErrorAction Stop`, followed by an increment. | A nonterminating error can bypass catch and still increment the count. Later execution must count only confirmed removals. |
| Age descriptions | Help/article wording refers to creation time; selection uses LastWriteTime. | Choose and document one age basis. New reports explicitly record LastWriteTimeUtc and a fixed cutoff. |
| Input validation | Invalid/nonpositive ages are not explicitly rejected; an empty extension broadens selection. | Require strict policy types/ranges and explicit patterns; make importer defaults and scope changes visible. |
| Path interpretation | Cleanup paths and removal targets are supplied to wildcard-capable `-Path` parameters or positionally. | Literal special characters can change interpretation. New traversal treats root and entry paths literally. |
| Link handling | Recursive traversal does not define a complete boundary policy for links/reparse points. | Make exclusions explicit, including roots and ancestors, and test link behaviour. |

## First rebuilt milestone

The report-only module addresses policy validation, classification, exclusions, age semantics and explicit error reporting. It does not repair the legacy script in place or implement removal, notification delivery or CSV import.

Initial acceptance evidence: 40 tests passed and 3 skipped on macOS with PowerShell 7.6.7/Pester 5.7.1. Skips cover Windows path rules, Windows junctions and a provisioned UNC share. Directory/metadata failures are injected at the filesystem adapter boundary; they are not claims of tested SMB or Windows ACL integration. The cross-platform workflow must run after the user commits and pushes before Windows/Linux confidence is established.


## HTML exporter follow-up

The scan result remains unchanged; presentation is handled by a separate exporter. Additional checks cover HTML escaping, explicit unsuccessful statuses, output boundaries, overwrite refusal, WhatIf, relative paths, links and cleanup when replacement fails. The local combined suite passed 61 tests with 3 platform-dependent skips on the same macOS runtime. Earlier counts above describe the original scanner milestone.
