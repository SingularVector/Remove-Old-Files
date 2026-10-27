-- Run once in the existing automation database, in a session with no open transaction.
-- Creates one configuration table and index; never creates a database, login or job.
-- SQL Server 2012+ T-SQL syntax (the bundled driver targets supported SQL Server versions).
SET XACT_ABORT ON;

-- Refuse tables, views or other schema objects that already use this name.
-- The leading semicolon makes THROW's statement termination explicit to SQL tooling.
IF OBJECT_ID(N'dbo.CleanupRules') IS NOT NULL
BEGIN
    ;THROW 50001, N'dbo.CleanupRules already exists; review its definition instead of overwriting it.', 1;
END;

BEGIN TRY
    BEGIN TRANSACTION;

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
END TRY
BEGIN CATCH
    -- Do not leave a partially created schema or an open transaction after a failure.
    IF XACT_STATE() <> 0
    BEGIN
        ROLLBACK TRANSACTION;
    END;

    ;THROW;
END CATCH;
