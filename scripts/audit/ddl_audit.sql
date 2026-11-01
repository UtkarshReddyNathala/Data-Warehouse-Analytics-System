/*
===============================================================================
DDL Script: Audit, Control and Logging Tables
===============================================================================
In short:
    Creates the tables that record what the pipeline did: each run, each step,
    every error, every file loaded and the bookmarks (watermarks) that show
    where the last run stopped. Nothing here is ever deleted.

Script Purpose:
    Creates the central audit and control tables used by every pipeline stage.
    Tables are created only if they do not exist, so this script is safe to
    re-run and never deletes audit history.

    audit.etl_setting          Key/value settings (data folder, timeouts, fault injection)
    audit.etl_batch            One row per pipeline execution (batch)
    audit.etl_step_log         One row per table/step inside a batch (row counts)
    audit.etl_error_log        Detailed SQL error information
    audit.file_ingestion_log   File arrival, checksum and processing status
    audit.cdc_control          Last processed LSN per CDC-enabled source table
    audit.etl_watermark        Watermarks for incremental (non-CDC) processing
    audit.perf_measurement     Manually recorded before/after query measurements
===============================================================================
*/

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

USE DataWarehouse;
GO

-- =============================================================================
-- audit.etl_setting
-- =============================================================================
IF OBJECT_ID(N'audit.etl_setting', N'U') IS NULL
BEGIN
    CREATE TABLE audit.etl_setting (
        setting_name   NVARCHAR(100)  NOT NULL CONSTRAINT PK_etl_setting PRIMARY KEY,
        setting_value  NVARCHAR(4000) NULL,
        description    NVARCHAR(500)  NULL,
        updated_at     DATETIME2(3)   NOT NULL CONSTRAINT DF_etl_setting_updated DEFAULT SYSDATETIME()
    );
END;
GO

-- Default settings (inserted only when missing, existing values are kept)
MERGE audit.etl_setting AS t
USING (VALUES
    (N'data_root',                    N'C:\sql\dwh_project\data\', N'Folder that contains the crm/ and erp/ CSV folders. Must be readable by the SQL Server service and end with a path separator.'),
    (N'bulk_insert_codepage',         N'65001', N'CODEPAGE for BULK INSERT. 65001 = UTF-8 (Windows). SQL Server on Linux only accepts RAW.'),
    (N'cdc_capture_timeout_seconds',  N'120',  N'How long the pipeline waits for the CDC capture process to read the latest changes.'),
    (N'ingestion_max_delete_pct',     N'50',   N'Safety limit: a file load that would delete more than this percentage of a source table is rejected.'),
    (N'dq_stop_on_critical',          N'1',    N'1 = stop the pipeline when a CRITICAL data quality rule fails.'),
    (N'fault_injection_point',        NULL,    N'Testing only. Set to e.g. SILVER:silver.crm_cust_info to force a failure at that point.')
) AS s (setting_name, setting_value, description)
ON t.setting_name = s.setting_name
WHEN NOT MATCHED BY TARGET THEN
    INSERT (setting_name, setting_value, description)
    VALUES (s.setting_name, s.setting_value, s.description);
GO

-- =============================================================================
-- audit.etl_batch
-- =============================================================================
IF OBJECT_ID(N'audit.etl_batch', N'U') IS NULL
BEGIN
    CREATE TABLE audit.etl_batch (
        batch_id          INT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_etl_batch PRIMARY KEY,
        pipeline_name     NVARCHAR(100)  NOT NULL,
        run_parameters    NVARCHAR(1000) NULL,
        start_time        DATETIME2(3)   NOT NULL CONSTRAINT DF_etl_batch_start DEFAULT SYSDATETIME(),
        end_time          DATETIME2(3)   NULL,
        duration_seconds  AS DATEDIFF(SECOND, start_time, end_time),
        status            NVARCHAR(30)   NOT NULL CONSTRAINT DF_etl_batch_status DEFAULT N'RUNNING',
        error_message     NVARCHAR(4000) NULL,
        failed_step_count INT            NOT NULL CONSTRAINT DF_etl_batch_failed_steps DEFAULT 0,  -- non-critical table failures
        dq_warning_count  INT            NOT NULL CONSTRAINT DF_etl_batch_dq_warnings  DEFAULT 0,  -- WARNING-level DQ results
        dq_critical_count INT            NOT NULL CONSTRAINT DF_etl_batch_dq_critical  DEFAULT 0,  -- FAILED / ERROR DQ results
        started_by        NVARCHAR(128)  NOT NULL CONSTRAINT DF_etl_batch_user DEFAULT SUSER_SNAME(),
        CONSTRAINT CK_etl_batch_status CHECK (status IN (N'RUNNING', N'SUCCESS', N'SUCCESS_WITH_WARNINGS', N'FAILED'))
    );
END;
GO

-- =============================================================================
-- audit.etl_step_log
-- =============================================================================
IF OBJECT_ID(N'audit.etl_step_log', N'U') IS NULL
BEGIN
    CREATE TABLE audit.etl_step_log (
        step_id         BIGINT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_etl_step_log PRIMARY KEY,
        batch_id        INT            NOT NULL CONSTRAINT FK_etl_step_log_batch REFERENCES audit.etl_batch (batch_id),
        stage           NVARCHAR(30)   NOT NULL,
        step_name       NVARCHAR(200)  NOT NULL,
        source_object   NVARCHAR(256)  NULL,
        target_object   NVARCHAR(256)  NULL,
        load_type       NVARCHAR(20)   NULL,
        start_time      DATETIME2(3)   NOT NULL CONSTRAINT DF_etl_step_start DEFAULT SYSDATETIME(),
        end_time        DATETIME2(3)   NULL,
        duration_ms     AS DATEDIFF(MILLISECOND, start_time, end_time),
        rows_read       BIGINT         NOT NULL CONSTRAINT DF_etl_step_read DEFAULT 0,
        rows_inserted   BIGINT         NOT NULL CONSTRAINT DF_etl_step_ins  DEFAULT 0,
        rows_updated    BIGINT         NOT NULL CONSTRAINT DF_etl_step_upd  DEFAULT 0,
        rows_deleted    BIGINT         NOT NULL CONSTRAINT DF_etl_step_del  DEFAULT 0,
        rows_rejected   BIGINT         NOT NULL CONSTRAINT DF_etl_step_rej  DEFAULT 0,
        status          NVARCHAR(20)   NOT NULL CONSTRAINT DF_etl_step_status DEFAULT N'RUNNING',
        message         NVARCHAR(4000) NULL,
        CONSTRAINT CK_etl_step_stage  CHECK (stage IN (N'PIPELINE', N'INGESTION', N'CDC', N'BRONZE', N'SILVER', N'DATA_QUALITY', N'GOLD')),
        CONSTRAINT CK_etl_step_status CHECK (status IN (N'RUNNING', N'SUCCESS', N'SKIPPED', N'WARNING', N'FAILED'))
    );

    CREATE INDEX IX_etl_step_log_batch ON audit.etl_step_log (batch_id, stage) INCLUDE (status, target_object);
END;
GO

-- =============================================================================
-- audit.etl_error_log
-- =============================================================================
IF OBJECT_ID(N'audit.etl_error_log', N'U') IS NULL
BEGIN
    CREATE TABLE audit.etl_error_log (
        error_id        BIGINT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_etl_error_log PRIMARY KEY,
        batch_id        INT            NULL,
        step_id         BIGINT         NULL,
        procedure_name  NVARCHAR(256)  NULL,
        object_name     NVARCHAR(256)  NULL,
        error_number    INT            NULL,
        error_severity  INT            NULL,
        error_state     INT            NULL,
        error_line      INT            NULL,
        error_procedure NVARCHAR(256)  NULL,
        error_message   NVARCHAR(4000) NULL,
        error_time      DATETIME2(3)   NOT NULL CONSTRAINT DF_etl_error_time DEFAULT SYSDATETIME()
    );

    CREATE INDEX IX_etl_error_log_batch ON audit.etl_error_log (batch_id);
END;
GO

-- =============================================================================
-- audit.file_ingestion_log
-- =============================================================================
IF OBJECT_ID(N'audit.file_ingestion_log', N'U') IS NULL
BEGIN
    CREATE TABLE audit.file_ingestion_log (
        file_id         INT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_file_ingestion_log PRIMARY KEY,
        config_id       INT            NOT NULL,
        file_name       NVARCHAR(260)  NOT NULL,
        file_path       NVARCHAR(1000) NOT NULL,
        file_hash       VARBINARY(32)  NULL,      -- SHA2_256 of the complete file content
        file_size       BIGINT         NULL,      -- bytes
        change_type     NVARCHAR(20)   NULL,      -- NEW / MODIFIED / REPROCESS / FORCED / UNCHANGED
        received_at     DATETIME2(3)   NOT NULL CONSTRAINT DF_file_log_received DEFAULT SYSDATETIME(),
        processed_at    DATETIME2(3)   NULL,
        batch_id        INT            NULL,
        status          NVARCHAR(20)   NOT NULL CONSTRAINT DF_file_log_status DEFAULT N'PENDING',
        rows_in_file    BIGINT         NULL,
        rows_inserted   BIGINT         NULL,
        rows_updated    BIGINT         NULL,
        rows_deleted    BIGINT         NULL,
        rows_rejected   BIGINT         NULL,
        error_message   NVARCHAR(4000) NULL,
        CONSTRAINT CK_file_log_status CHECK (status IN (N'PENDING', N'PROCESSING', N'SUCCESS', N'FAILED', N'SKIPPED_DUPLICATE'))
    );

    CREATE INDEX IX_file_ingestion_log_lookup ON audit.file_ingestion_log (config_id, status, file_id) INCLUDE (file_hash);
END;
GO

-- =============================================================================
-- audit.cdc_control  (LSN watermark per CDC capture instance)
-- =============================================================================
IF OBJECT_ID(N'audit.cdc_control', N'U') IS NULL
BEGIN
    CREATE TABLE audit.cdc_control (
        config_id           INT            NOT NULL CONSTRAINT PK_cdc_control PRIMARY KEY,
        table_name          NVARCHAR(256)  NOT NULL,
        capture_instance    NVARCHAR(128)  NOT NULL,
        last_processed_lsn  BINARY(10)     NULL,   -- NULL = never processed -> initial snapshot
        current_batch_id    INT            NULL,
        last_processed_at   DATETIME2(3)   NULL,
        status              NVARCHAR(20)   NOT NULL CONSTRAINT DF_cdc_control_status DEFAULT N'IDLE',
        last_resync_at      DATETIME2(3)   NULL,
        last_resync_reason  NVARCHAR(400)  NULL,
        last_error          NVARCHAR(4000) NULL,
        CONSTRAINT CK_cdc_control_status CHECK (status IN (N'IDLE', N'PROCESSING', N'FAILED'))
    );
END;
GO

-- =============================================================================
-- audit.etl_watermark  (rowversion / datetime / bronze_id / snapshot hash)
-- =============================================================================
IF OBJECT_ID(N'audit.etl_watermark', N'U') IS NULL
BEGIN
    CREATE TABLE audit.etl_watermark (
        watermark_name   NVARCHAR(200)  NOT NULL CONSTRAINT PK_etl_watermark PRIMARY KEY,
        watermark_type   NVARCHAR(20)   NOT NULL,
        value_binary     VARBINARY(32)  NULL,
        value_datetime   DATETIME2(7)   NULL,
        value_bigint     BIGINT         NULL,
        last_batch_id    INT            NULL,
        updated_at       DATETIME2(3)   NOT NULL CONSTRAINT DF_etl_watermark_updated DEFAULT SYSDATETIME(),
        CONSTRAINT CK_etl_watermark_type CHECK (watermark_type IN (N'ROWVERSION', N'DATETIME', N'BIGINT', N'HASH'))
    );
END;
GO

-- =============================================================================
-- audit.perf_measurement  (measured query timings, before and after a change)
-- =============================================================================
IF OBJECT_ID(N'audit.perf_measurement', N'U') IS NULL
BEGIN
    CREATE TABLE audit.perf_measurement (
        measurement_id   INT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_perf_measurement PRIMARY KEY,
        query_name       NVARCHAR(200)  NOT NULL,
        phase            NVARCHAR(10)   NOT NULL,
        elapsed_ms       INT            NULL,
        cpu_ms           INT            NULL,
        logical_reads    BIGINT         NULL,
        notes            NVARCHAR(1000) NULL,
        measured_at      DATETIME2(3)   NOT NULL CONSTRAINT DF_perf_measured DEFAULT SYSDATETIME(),
        CONSTRAINT CK_perf_phase CHECK (phase IN (N'BEFORE', N'AFTER'))
    );
END;
GO

PRINT 'Audit tables ready.';
GO
