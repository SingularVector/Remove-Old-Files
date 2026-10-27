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
