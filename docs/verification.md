# Verification evidence

Evidence applies to the stated revision and environment, not every future feature or deployment.

## Hosted module tests

The workflow for commit `88b97662609e4076280df59ab981f8d0a758bc91` completed successfully on 26 October 2026:

| Hosted platform | Passed | Skipped |
| --- | --- | --- |
| Windows | 106 | 1 |
| macOS | 104 | 3 |
| Ubuntu Linux | 103 | 4 |

[Workflow run and per-job logs](https://github.com/SingularVector/Remove-Old-Files/actions/runs/40390107411).

Different totals reflect platform-gated path, link/junction and case-comparison checks. Windows completed its native junction/path cases. The provisioned UNC-share test remains skipped; neither hosted success nor injected permission failures establish real SMB/ACL behaviour. These jobs used the hosted PowerShell runtimes, not a pinned test of the minimum supported 7.4 runtime.

## Local module evidence

The same module milestone passed 104 tests with 3 skips on macOS, PowerShell 7.6.7 and Pester 5.7.1. Function relocation into Public and Private files was checked against the previous commit: all 13 function definitions were unchanged. A copied package imported and planned in a fresh PowerShell process outside the source checkout.

## SQL Server scope and job discovery

The supported target is now Windows only, SQL Server with integrated authentication by default or an optional SQL credential and one configuration table. The PostgreSQL coordination prototype was removed; its experimental tests are not part of the supported solution.

Local tests for Get-RetentionJob mock the connection/query boundaries. SQL helper tests use an in-memory data reader and a test connection to verify typed/null values, timeouts and disposal after success, failed login, failed command creation, query failure and command-disposal failure. They also verify optional SQL credential forwarding and password-free connection strings. Windows-only tests construct the runtime provider in both authentication modes without opening a connection. The non-Windows database adapter is explicitly rejected. These checks do not demonstrate a live SQL Server connection or login in either authentication mode; those remain Windows deployment checks.

The Windows-only CI workflow must run after this change is pushed. Test the deployment script and actual discovery against the intended SQL Server before treating discovery as integration-verified. Existing hosted Windows results above apply to the earlier core-module revision.

After the self-contained SQL helper change, the complete suite passed 118 tests with 5 platform-dependent skips on the development Mac (PowerShell 7.6.9). The source style check and standalone package/import checks also passed. The two new provider-construction tests require Windows and were skipped locally. No live SQL Server was used.

The maintained-driver and SQL policy-creation update passed 136 tests with 5 platform-dependent skips on the development Mac (PowerShell 7.6.9). The full source style check passed, including aligned hashtable assignments; an intentionally misaligned fixture was rejected. The locked SQL client rebuild completed from the restored dependency cache. Tests verified every bundled file checksum, the manifest/package boundary, fresh-process import, typed SQL parameter binding and policy creation/preview behaviour. These are local and mocked checks, not evidence of a live SQL INSERT, login or native-driver connection on Windows.

The VM lab addition passed 139 tests with 5 platform-dependent skips locally. New fixture tests verify saved-policy round trips, actual file timestamps, fixed-time candidate sets, CSV compatibility, read-only previews, existing-directory refusal and real opt-in removal inside disposable test directories. They also reproduce the hidden-file removal failure: four candidates, three successful deletions and one recorded error. Source style checks passed. Windows Hidden-attribute behaviour remains subject to the Windows test run; local deletion evidence comes from macOS.

## 2.0.0-rc1 verification

The preceding revision 895f855ab29338fd4dd913eed3bccd7109ab6bc0 passed [Windows CI](https://github.com/SingularVector/Remove-Old-Files/actions/runs/40586239029). This establishes the bundled-driver baseline, not a hosted test result for the release-candidate changes.

The release candidate's local complete run passed 161 tests with 5 platform-dependent skips. Added checks cover SQL job configuration preflight, enabled/disabled rules, parameterised names, sequential real deletion inside disposable fixtures, unchanged previews, per-rule status values, inaccessible/read-only failures, stop-on-status-write-failure behaviour, removed rules and scheduled-process exit codes. The lab now confirms successful hidden-file deletion; earlier hidden-file-failure evidence above is historical. Source style, manifest completeness, driver checksums and fresh-process package import also passed.

The live Windows SQL acceptance tool is implemented but has not been run from the development Mac. It remains a required stable-release gate, together with Windows CI on the current revision. See [release readiness](release-readiness.md) for the exact command. No live database, login, scheduling or production cleanup was modified during local verification.
