# Remove Old Files

## Windows cleanup module

The rebuilt engine has a report-only development milestone in `src/RetentionEngine`. Read the [behaviour specification](docs/retention-engine-specification.md) and [report-only usage](docs/report-only-usage.md) before trying it. The scanner does not delete files; a separate exporter can write a standalone HTML report outside the scanned root. The script and usage instructions below describe the legacy implementation, not the new module.

*Remove-OldFiles.ps1* is a complete script to help SysAdmins rotating *stale* files in any directory either local or remote.

For the rebuilt CSV importer and multi-policy reporting, see [CSV migration](docs/csv-migration.md).

Explicitly opted-in single-policy execution is documented in [controlled cleanup](docs/controlled-cleanup.md). Read the default, preview, confirmation and race-limit behaviour before trying it.

For the public/private module layout, the cleanup entry point and a portable build, see [module structure and distribution](docs/module-structure.md).

The target is Windows with SQL Server with integrated authentication by default or an optional SQL credential and one rules table. Use [Get-RetentionJob and New-RetentionPolicy](docs/sqlserver-jobs.md) to discover job names and create rules directly in SQL, with WhatIf previews. The maintained SQL driver is included for offline Windows x64 deployment; no SqlServer PowerShell module is required. SQL-backed execution and last-result updates are the next integration step; machine assignment remains the systems engineer’s responsibility. See [verification evidence](docs/verification.md) for actual test coverage.

## Legacy script reference

The following instructions describe the original CSV-based script, retained for reference. They are not the SQL Server module configuration.

### Script Components

Script support both PowerShell and PowerShell core and is designed to be run as either a scheduled task or as part of any other automation framework like *System Center Orchestrator*.

*Remove-OldFiles.ps1* uses an external *comma separated file (csv)* file named **FilePaths.csv** as a centralized configuration file for the maximum flexibility, fields and their usage are described in the table below

| Column Name         | **Description**                     | **Values**                                | Notes                                                        |
| ------------------- | ----------------------------------- | ----------------------------------------- | ------------------------------------------------------------ |
| *CleanupPath*       | Path to scan for old files          | Local or UNC Path                         | If empty script will log an exception                        |
| *FileExtension*     | Files to search for cleanup         | Any string like **log**, **pdf**, **txt** | If empty will match all files (\*.\*)                        |
| *AgeTolerance*      | Tolerance in days                   | Any number like 30 or 90                  | If empty will default to **90 days**                         |
| *IncludeSubFolders* | Defines if recursion should be used | **0** or **1**                            | If not specified it will default to **0** (no recursion)<br /> Any other value will cause script to log an exception |

**Note:** Configuration file name can be changed as long it is updated in **$cleanupPath** variable

## First Run and Customization

In addition to updating the CSV file with path and options script needs a few customization before being ready for production.

### Logging

Script integrates a full [logging function](https://github.com/SingularVector/New-LogEntry) to make troubleshooting easier in case of issues, all log messages have been already configure <sup>1</sup> the only required step is setting the correct path where log will be written via the ***$logPath*** variable

```powershell
[string]$logPath = '\\MyServer\ScriptLog\Remove-OldFiles\'
```

Log file name can be customized via the ***$logName*** variable

```powershell
# Define log name
[string]$logFilePath = $logPath + $dateString + '-RemoveOldFiles.log'
```

**Note:** Logging function is also available as a [standalone download](https://github.com/SingularVector/New-LogEntry) or as part of the **[IT-ToolBox](https://github.com/SingularVector/IT-ToolBox)** module.

### Notifications

In addition to log file creation script supports mail notifications via Email **only** when an exception is thrown during execution.

All mail related configuration parameters, included HTML code for mail body, are defined in a region named ***Mail Settings Configuration***, before script execution at least the following parameters should be set to allow correct operation

```powershell
# Set mail settings
[string]$mailSender = # Mail Sender
[string[]]$mailRecipients = # 'somebody@somewhere.com', 'admin@somewhere.com'
[string]$smtpRelay = #smtpRelay
```

### Ignore Folders

Folders can be ignored, useful when using recursion, creating a file named **ignore** underneath the path that should be skipped. File name can be customized updating the **$ignoreFile** variable value

```powershell
# Define Ignore control file
[string]$ignoreFile = 'ignore'
```

----

<sup>1</sup> All messages can be customized and additional ones can be defined as required.
