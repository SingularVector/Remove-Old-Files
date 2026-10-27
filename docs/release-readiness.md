# RetentionEngine 2.0.0-rc1

The implementation scope is frozen for this release candidate: Windows x64, PowerShell 7.4+, SQL Server, one rules table, named sequential jobs, per-rule last-result fields, explicit cleanup opt-in, scan HTML and structured execution results. No worker registration, parallel agent engine, second database platform or new report format is required for release.

## What is implemented

- Discover job names and create rules through the public commands.
- Load a job's enabled rules, validate their configuration and reject overlapping roots before scanning.
- Plan by default; support Execute/WhatIf and per-file confirmation.
- Record UTC completion, exception bit and machine name after each real rule attempt. Previews and disabled rules make no status writes.
- Check status-write permissions before deletion and stop if recording fails later.
- Delete eligible hidden logs; retain read-only-file refusal and existing scope/link/marker protections.
- Use the maintained SQL driver bundled with its locked dependencies for offline deployment.
- Run the same command through a scheduled-task entry point with JSON output and meaningful process exit codes.

## Final acceptance on the target platform

The stable release is not declared yet. The current revision needs a passing Windows CI run and a successful live SQL acceptance run. Earlier passing CI establishes a baseline, not proof of changes made afterwards.

On the disposable Windows x64 VM, copy/extract the complete repository layout. Use PowerShell 7.4 or later. Deploy database/sqlserver/001_cleanup_rules.sql manually into an existing disposable automation database. The SQL Server certificate must be trusted and match its connection name; the module does not bypass certificate validation.

Run the acceptance test with an account authorised to SELECT, INSERT and UPDATE the cleanup table, and a new local directory:

```powershell
$test =
@{
    ServerInstance = 'SQL01'
    Database       = 'AutomationLab'
    LiteralPath    = 'C:\RetentionRelease01'
}

./tools/Test-SqlServerRelease.ps1 @test -Execute
```

Integrated authentication uses that PowerShell process's Windows account. Repeat with Credential if SQL authentication is part of the deployment. The test requires Execute because it really deletes the synthetic files it creates. It never creates a database, table, login or scheduled task. It leaves two uniquely named SQL rules, retained fixtures and pre-cleanup HTML for inspection; note the returned JobName so the SE can remove this test configuration afterwards. Stop and inspect if any assertion fails; do not rerun blindly against an uncertain write.

The test checks both preview modes with unchanged NULL last-result fields; eight real file deletions including hidden logs; persisted timestamps, machine name and false exception bits; a read-only-file failure recorded as true; and a later successful attempt clearing that bit. Other files and protected subtrees must remain. ACL, locked-file and UNC-share behaviour still need those environments when used in production.

## Package and deploy

```powershell
./tools/Test-SourceStyle.ps1
Invoke-Pester ./tests
$package = ./tools/Build-Module.ps1 -DestinationPath 'C:\RetentionBuild01'
```

The module package contains its SQL dependencies and licences; target machines do not restore packages. Keep the whole version directory together. The scheduled-task example and acceptance tools are part of the full repository snapshot, not the module-only package. Follow [SQL jobs](sqlserver-jobs.md) when configuring the task account, output capture and no-overlap scheduling.

After current Windows CI and live SQL acceptance pass, remove the rc1 prerelease marker for 2.0.0, record the exact verification revision and build a fresh package. Publishing or pushing remains a separate user decision. Keep backups and the previous package for rollback; a code rollback cannot restore already deleted files.
