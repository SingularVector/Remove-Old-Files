# Remove Old Files

## Windows cleanup module

RetentionEngine 2.0.0-rc1 is a release candidate for Windows x64 and PowerShell 7.4 or later. A single SQL Server table stores named cleanup rules. The module discovers job names, creates policies, runs enabled rules sequentially and records each rule's last execution time, exception flag and machine name. Integrated authentication is the default; an optional SQL credential is supported. The maintained SQL driver and dependencies are bundled for offline deployment.

```powershell
Import-Module ./src/RetentionEngine/RetentionEngine.psd1 -Force
Get-RetentionJob -ServerInstance SQL01 -Database Automation

Invoke-RetentionCleanup -ServerInstance SQL01 -Database Automation -JobName AppLogs
Invoke-RetentionCleanup -ServerInstance SQL01 -Database Automation -JobName AppLogs -Execute -WhatIf
Invoke-RetentionCleanup -ServerInstance SQL01 -Database Automation -JobName AppLogs -Execute -Confirm
```

Report-only mode is the default. Deletion requires Execute. Report-only and WhatIf runs never update SQL status. Existing local-policy and CSV reporting commands remain available. Systems engineers choose and schedule the machine; there is no worker registry, concurrent execution engine or automatic job assignment.

Start with the [Windows VM walkthrough](docs/vm-testing.md), then read [SQL Server jobs](docs/sqlserver-jobs.md) and [release readiness](docs/release-readiness.md). For the remaining details, see [controlled cleanup](docs/controlled-cleanup.md), [module packaging](docs/module-structure.md) and [verification evidence](docs/verification.md).

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
