# Verification evidence

Evidence applies to the stated revision and environment. The supported production target is Windows x64; macOS is used for local development tests only.

## Windows baseline

Revision bad36eb5faaae1cfa7c9156549e30f46a48aa706 passed [Windows CI](https://github.com/SingularVector/Remove-Old-Files/actions/runs/40590227876): 164 tests passed, none failed and 2 were skipped. The run includes driver construction, Windows filesystem cases and scheduled-entry process checks. It does not demonstrate a live SQL Server connection, account permissions or deployment to a real automation database.

The repository-cleanup revision relocates the launcher and lab tool without changing the module interface. Its local verification is recorded below; Windows CI must also run on the new revision.

After cleanup, the full local suite passed 161 tests with 5 platform-dependent skips. The root launcher and relocated lab utility were exercised by the existing process/fixture tests. Source style checks, relative documentation links, all PowerShell guide examples and the standalone SVG were validated. The diagram was rendered and inspected. Removed files were backed up outside the repository; the local editorial outline was preserved separately.

## Local checks

The current complete run passed 163 tests with 5 platform-dependent skips on macOS, PowerShell 7.6.9 and Pester 5.7.1. Tests use disposable directories for actual removal and mocks at the SQL boundary. They cover configuration preflight, sequential cleanup, disabled rules, unchanged previews, per-rule status values, inaccessible/read-only failures, stop-on-status-write-failure behaviour and process exit codes.

HTML tests verify that 2,000 routine age/pattern skips produce no detail rows while retaining aggregate totals and the original scan data. Protected directories, skipped links and recursion exclusions remain visible. The refreshed synthetic sample was checked against the same rules.

Package tests verify the complete manifest file list, the pinned SQL bundle's checksums and fresh-process import outside the checkout. Source style checks enforce valid PowerShell syntax, four-space indentation, brace-only lines and aligned hashtable assignments.

## SQL deployment review

The original and revised table-creation scripts passed Microsoft's ScriptDom 170.191.0 parser under T-SQL 110, 140, 150, 160 and 170 grammars (SQL Server 2012, 2017, 2019, 2022 and 2025), with zero parse errors. An AST-generated comparison confirmed unchanged columns, defaults, constraints and index definitions after transaction/error-handling changes. The parser was used from temporary development storage, not added as a runtime dependency.

Syntax checks are not a live deployment and do not reproduce an unspecified editor diagnostic. The DDL must still be exercised against the intended SQL Server environment.

## Live acceptance still required

The live SQL test is tools/Test-SqlServerRelease.ps1. It is implemented but has not been executed from the development Mac. Its assertions cover INSERT/SELECT/UPDATE, both preview modes, actual synthetic-file deletion, timestamps/machine names, a recorded exception and a later success clearing that bit.

Run it in the Windows VM using the intended account and authentication mode. ACL failures, locked files and real UNC shares require those environments when used. The hosted runtimes are not a pinned certification of the minimum supported PowerShell 7.4 runtime.

See [release readiness](release-readiness.md) for the acceptance command and [implementation and operations](implementation-guide.md) for the supported workflow.
