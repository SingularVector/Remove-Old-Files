# Change history

## Unreleased — 2.0.0-rc1

- Replace the former standalone CSV script with a Windows x64 PowerShell module and central SQL Server rules table.
- Discover named jobs, create rules and execute enabled rules sequentially with per-rule UTC completion, exception flag and machine-name updates.
- Plan by default; require Execute for deletion and keep WhatIf free of file deletion and SQL status writes.
- Retain scope, link, ignore-marker and metadata checks; support hidden-file deletion while refusing read-only files.
- Check status-write permissions before deletion and stop on later recording failures.
- Bundle maintained Microsoft.Data.SqlClient 6.1.7 LTS and locked dependencies for offline deployment.
- Provide standalone scan HTML, structured execution results, CSV migration/reporting helpers and an opt-in live SQL acceptance exercise.
- Harden table deployment with an existing-object guard and rollback/rethrow handling.
- Place the scheduled-task entry point at the repository root as Invoke-RetentionJob.ps1; group lab and maintenance utilities under tools.
- Remove superseded legacy files, generated sample/build outputs and duplicate milestone documents; consolidate implementation and operations guidance with an architecture diagram.
- Hold the stable release until the current Windows CI and live SQL acceptance gates pass.

## Version 1.1.0

- Update the logging function, logging-message spelling and file encoding.

## Version 1.0.0

- Initial standalone script release.
