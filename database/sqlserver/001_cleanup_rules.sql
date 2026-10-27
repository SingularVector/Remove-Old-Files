-- Run once inside the existing automation database, using its normal deployment process.
-- This creates one configuration table. It does not create a database, login or job.
SET XACT_ABORT ON;
BEGIN TRANSACTION;

IF OBJECT_ID(N'dbo.CleanupRules', N'U') IS NOT NULL
BEGIN
    THROW 50001, 'dbo.CleanupRules already exists; review its schema instead of overwriting it.', 1;
END;

CREATE TABLE dbo.CleanupRules
(
    RuleId uniqueidentifier NOT NULL
        CONSTRAINT DF_CleanupRules_RuleId DEFAULT NEWID(),
    JobName nvarchar(128) NOT NULL,
    CleanupPath nvarchar(2048) NOT NULL,
    FileExtension nvarchar(64) NOT NULL,
    RetentionDays int NOT NULL,
    IncludeSubfolders bit NOT NULL
        CONSTRAINT DF_CleanupRules_IncludeSubfolders DEFAULT (0),
    Enabled bit NOT NULL
        CONSTRAINT DF_CleanupRules_Enabled DEFAULT (1),
    LastExecutedAtUtc datetime2(7) NULL,
    LastHadExceptions bit NULL,
    LastMachineName nvarchar(128) NULL,
    CONSTRAINT PK_CleanupRules PRIMARY KEY (RuleId),
    CONSTRAINT CK_CleanupRules_JobName CHECK (LEN(LTRIM(RTRIM(JobName))) > 0),
    CONSTRAINT CK_CleanupRules_CleanupPath CHECK (LEN(LTRIM(RTRIM(CleanupPath))) > 0),
    CONSTRAINT CK_CleanupRules_RetentionDays CHECK (RetentionDays BETWEEN 1 AND 36500)
);

CREATE INDEX IX_CleanupRules_JobName ON dbo.CleanupRules (JobName) INCLUDE (Enabled);
COMMIT TRANSACTION;
