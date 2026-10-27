# Release readiness: 2.0.0-rc1

The agreed implementation is complete: one SQL Server rules table, named sequential jobs, preview-first cleanup, per-rule last-result fields, scan HTML and structured execution results. The repository cleanup does not add features or change the module's public commands.

## Remaining stable-release gates

1. A passing Windows CI run on the repository-cleanup revision, including the relocated root launcher and tools.
2. A successful live SQL acceptance run in the disposable Windows x64 VM, as the intended task account. Repeat with SQL authentication if used in production.

The preceding revision bad36eb passed [Windows CI](https://github.com/SingularVector/Remove-Old-Files/actions/runs/40590227876). This does not establish a hosted result for later layout changes, and it is not a live SQL connection test.

Deploy the table manually in a disposable automation database, then run from the repository root:

```powershell
$acceptance =
@{
    ServerInstance = 'SQL01'
    Database       = 'AutomationLab'
    LiteralPath    = 'C:\RetentionRelease01'
}

./tools/Test-SqlServerRelease.ps1 @acceptance -Execute
```

This creates two synthetic rules under a unique job name, performs real cleanup of its fixtures and leaves the rules and retained files for inspection. It checks previews, persisted statuses, hidden-file removal, a read-only-file failure and exception-bit reset. Do not point it at existing data. The database, table, account and new local lab path are explicit prerequisites; the test does not create a service or schedule.

After both gates pass, record the exact verified revision, remove the rc1 marker for 2.0.0 and build a fresh package. Publishing or pushing remains a separate user decision. A code rollback cannot restore files already deleted.

See the [implementation guide](implementation-guide.md) for deployment, permissions and operation, and [verification](verification.md) for current evidence.
