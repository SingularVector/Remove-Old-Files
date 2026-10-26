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

## Central-store evidence

The PostgreSQL contract is tested independently by `tools/Test-PostgreSqlStore.ps1`. Its output records assertion count, concurrent-claim check, PostgreSQL version and image ID. This is not evidence that a PowerShell worker or the deletion command is integrated with central storage; that connection is not implemented yet.


On 26 October 2026 the local prototype passed 34 database assertions and one competing-client claim check against PostgreSQL 18.6. The container image ID was `sha256:10a5c69a83035ab5239f5620d708520e8b28f5aa1f2b20143e6024532edadfb5`. The original module regression run still passed 104 tests with 3 skips. The disposable database container was removed after the test; no application database was created or connected to the worker module.
