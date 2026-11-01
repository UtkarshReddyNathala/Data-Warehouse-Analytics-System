/*
===============================================================================
CDC Framework Procedures
===============================================================================
In short:
    Turns on SQL Server Change Data Capture (CDC), which records every insert,
    update and delete in the CRM source tables. It also makes sure CDC has
    caught up before the pipeline reads the changes.

Script Purpose:
    etl.usp_enable_cdc
        Enables SQL Server Change Data Capture on the database and on every
        source table configured with load_type = 'CDC' in audit.etl_config,
        plus the source.cdc_heartbeat table. Registers each table in
        audit.cdc_control. Safe to run many times.

    etl.usp_cdc_sync_capture
        Makes sure the CDC capture process has read the transaction log up to
        "now" before changes are extracted. It writes a heartbeat row into a
        CDC-tracked table and waits until that row appears in the change table.
        Because the capture process reads the log in order, every change that
        was committed before the heartbeat has then been captured as well.
        If the SQL Server Agent capture job is not running (for example on a
        laptop without Agent), it runs one manual scan with sys.sp_cdc_scan.

Prerequisites:
    - SQL Server edition with CDC (Developer, Standard or Enterprise).
    - SQL Server Agent running for automatic capture/cleanup jobs
      (Docker: MSSQL_AGENT_ENABLED=true).
    - sysadmin to enable CDC on the database, db_owner for the tables.
===============================================================================
*/

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

USE DataWarehouse;
GO

-- =============================================================================
-- etl.usp_enable_cdc
-- =============================================================================
CREATE OR ALTER PROCEDURE etl.usp_enable_cdc
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @config_id INT, @schema SYSNAME, @table SYSNAME, @ci SYSNAME, @exists INT;
    DECLARE @todo TABLE (config_id INT NULL, source_schema SYSNAME, source_table SYSNAME, capture_instance SYSNAME);

    -- 1. Database level ---------------------------------------------------------
    IF NOT EXISTS (SELECT 1 FROM sys.databases WHERE database_id = DB_ID() AND is_cdc_enabled = 1)
    BEGIN
        PRINT '>> Enabling CDC on database ' + DB_NAME();
        EXEC sys.sp_cdc_enable_db;
    END;

    -- 2. Tables -----------------------------------------------------------------
    INSERT INTO @todo (config_id, source_schema, source_table, capture_instance)
    SELECT config_id, source_schema, source_table, capture_instance
    FROM audit.etl_config
    WHERE load_type = N'CDC';

    -- Heartbeat table (not part of the ETL configuration)
    INSERT INTO @todo (config_id, source_schema, source_table, capture_instance)
    VALUES (NULL, N'source', N'cdc_heartbeat', N'source_cdc_heartbeat');

    WHILE EXISTS (SELECT 1 FROM @todo)
    BEGIN
        SELECT TOP (1) @config_id = config_id, @schema = source_schema, @table = source_table, @ci = capture_instance
        FROM @todo ORDER BY source_table;

        EXEC sys.sp_executesql
            N'SELECT @e = COUNT(*) FROM cdc.change_tables WHERE capture_instance = @ci;',
            N'@ci SYSNAME, @e INT OUTPUT', @ci = @ci, @e = @exists OUTPUT;

        IF @exists = 0
        BEGIN
            PRINT '>> Enabling CDC on ' + @schema + '.' + @table + ' (capture instance ' + @ci + ')';
            EXEC sys.sp_cdc_enable_table
                @source_schema        = @schema,
                @source_name          = @table,
                @role_name            = NULL,      -- no gating role (local project)
                @capture_instance     = @ci,
                @supports_net_changes = 1;         -- requires a primary key
        END;

        IF @config_id IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM audit.cdc_control WHERE config_id = @config_id)
            INSERT INTO audit.cdc_control (config_id, table_name, capture_instance, status)
            VALUES (@config_id, @schema + N'.' + @table, @ci, N'IDLE');

        DELETE FROM @todo WHERE source_schema = @schema AND source_table = @table;
    END;

    -- 3. Report -----------------------------------------------------------------
    EXEC sys.sp_executesql N'
        SELECT ct.capture_instance,
               OBJECT_SCHEMA_NAME(ct.source_object_id) + N''.'' + OBJECT_NAME(ct.source_object_id) AS source_table,
               ct.supports_net_changes,
               ct.create_date
        FROM cdc.change_tables AS ct
        ORDER BY ct.capture_instance;';
END;
GO

-- =============================================================================
-- etl.usp_cdc_sync_capture
-- =============================================================================
CREATE OR ALTER PROCEDURE etl.usp_cdc_sync_capture
    @timeout_seconds INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @@TRANCOUNT > 0
        THROW 50300, 'etl.usp_cdc_sync_capture must not run inside a transaction.', 1;

    SET @timeout_seconds = ISNULL(@timeout_seconds,
                                  TRY_CAST(audit.fn_get_setting(N'cdc_capture_timeout_seconds') AS INT));
    SET @timeout_seconds = ISNULL(@timeout_seconds, 120);

    DECLARE @token    UNIQUEIDENTIFIER = NEWID();
    DECLARE @deadline DATETIME2(3)     = DATEADD(SECOND, @timeout_seconds, SYSDATETIME());
    DECLARE @found    INT              = 0;
    DECLARE @msg      NVARCHAR(2048);

    -- The heartbeat is committed after every change we care about.
    INSERT INTO source.cdc_heartbeat (token) VALUES (@token);

    WHILE SYSDATETIME() < @deadline
    BEGIN
        EXEC sys.sp_executesql
            N'SELECT @f = COUNT(*) FROM cdc.source_cdc_heartbeat_CT WHERE token = @t;',
            N'@t UNIQUEIDENTIFIER, @f INT OUTPUT', @t = @token, @f = @found OUTPUT;

        IF @found > 0 BREAK;

        -- Manual scan when the Agent capture job is not running.
        -- If the job IS running, sp_cdc_scan raises an error which we ignore.
        BEGIN TRY
            EXEC sys.sp_cdc_scan @maxtrans = 500, @maxscans = 10, @continuous = 0, @pollinginterval = 0;
        END TRY
        BEGIN CATCH
        END CATCH;

        EXEC sys.sp_executesql
            N'SELECT @f = COUNT(*) FROM cdc.source_cdc_heartbeat_CT WHERE token = @t;',
            N'@t UNIQUEIDENTIFIER, @f INT OUTPUT', @t = @token, @f = @found OUTPUT;

        IF @found > 0 BREAK;

        WAITFOR DELAY '00:00:01';
    END;

    -- Housekeeping: heartbeat rows are only needed for a short time
    DELETE FROM source.cdc_heartbeat WHERE created_at < DATEADD(DAY, -1, SYSDATETIME());

    IF @found = 0
    BEGIN
        SET @msg = N'CDC capture did not reach the latest changes within ' + CAST(@timeout_seconds AS NVARCHAR(10))
                 + N' seconds. Check that SQL Server Agent and the cdc.' + DB_NAME() + N'_capture job are running.';
        THROW 50301, @msg, 1;
    END;
END;
GO

PRINT 'CDC framework procedures ready.';
GO
