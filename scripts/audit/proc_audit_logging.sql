/*
===============================================================================
Audit Helper Procedures and Functions
===============================================================================
In short:
    Small helper procedures used by every part of the pipeline. They start and
    end a run, log each step and its row counts, save errors and read or save
    settings.

Script Purpose:
    Small reusable building blocks used by every pipeline stage:

    audit.fn_get_setting            Read a value from audit.etl_setting
    etl.usp_set_setting             Insert/update a setting
    audit.usp_start_batch           Open a batch            (audit.etl_batch)
    audit.usp_end_batch             Close a batch
    audit.usp_step_start            Open a step             (audit.etl_step_log)
    audit.usp_step_end              Close a step with row counts
    audit.usp_log_error             Write ERROR_*() details (call inside CATCH)
    etl.usp_get_watermark           Read a watermark        (audit.etl_watermark)
    etl.usp_set_watermark           Insert/update a watermark
    etl.usp_check_fault_injection   Testing hook: raise an error at a named point
===============================================================================
*/

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

USE DataWarehouse;
GO

-- =============================================================================
-- audit.fn_get_setting
-- =============================================================================
CREATE OR ALTER FUNCTION audit.fn_get_setting (@setting_name NVARCHAR(100))
RETURNS NVARCHAR(4000)
AS
BEGIN
    RETURN (SELECT setting_value FROM audit.etl_setting WHERE setting_name = @setting_name);
END;
GO

-- =============================================================================
-- etl.usp_set_setting
-- Usage: EXEC etl.usp_set_setting N'data_root', N'C:\sql\dwh_project\data\';
-- =============================================================================
CREATE OR ALTER PROCEDURE etl.usp_set_setting
    @setting_name  NVARCHAR(100),
    @setting_value NVARCHAR(4000)
AS
BEGIN
    SET NOCOUNT ON;

    -- The data folder must end with a path separator ('\' on Windows, '/' on Linux)
    IF @setting_name = N'data_root' AND @setting_value IS NOT NULL
       AND RIGHT(@setting_value, 1) NOT IN (N'\', N'/')
        SET @setting_value += CASE WHEN CHARINDEX(N'/', @setting_value) > 0 THEN N'/' ELSE N'\' END;

    UPDATE audit.etl_setting
    SET setting_value = @setting_value,
        updated_at    = SYSDATETIME()
    WHERE setting_name = @setting_name;

    IF @@ROWCOUNT = 0
        INSERT INTO audit.etl_setting (setting_name, setting_value)
        VALUES (@setting_name, @setting_value);
END;
GO

-- =============================================================================
-- audit.usp_start_batch
-- =============================================================================
CREATE OR ALTER PROCEDURE audit.usp_start_batch
    @pipeline_name  NVARCHAR(100),
    @run_parameters NVARCHAR(1000) = NULL,
    @batch_id       INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO audit.etl_batch (pipeline_name, run_parameters, status)
    VALUES (@pipeline_name, @run_parameters, N'RUNNING');

    SET @batch_id = CAST(SCOPE_IDENTITY() AS INT);
END;
GO

-- =============================================================================
-- audit.usp_end_batch
-- =============================================================================
CREATE OR ALTER PROCEDURE audit.usp_end_batch
    @batch_id          INT,
    @status            NVARCHAR(30),
    @error_message     NVARCHAR(4000) = NULL,
    @failed_step_count INT = NULL,
    @dq_warning_count  INT = NULL,
    @dq_critical_count INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE audit.etl_batch
    SET end_time          = SYSDATETIME(),
        status            = @status,
        error_message     = @error_message,
        failed_step_count = ISNULL(@failed_step_count, failed_step_count),
        dq_warning_count  = ISNULL(@dq_warning_count, dq_warning_count),
        dq_critical_count = ISNULL(@dq_critical_count, dq_critical_count)
    WHERE batch_id = @batch_id;
END;
GO

-- =============================================================================
-- audit.usp_step_start
-- =============================================================================
CREATE OR ALTER PROCEDURE audit.usp_step_start
    @batch_id      INT,
    @stage         NVARCHAR(30),
    @step_name     NVARCHAR(200),
    @source_object NVARCHAR(256) = NULL,
    @target_object NVARCHAR(256) = NULL,
    @load_type     NVARCHAR(20)  = NULL,
    @step_id       BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO audit.etl_step_log (batch_id, stage, step_name, source_object, target_object, load_type, status)
    VALUES (@batch_id, @stage, @step_name, @source_object, @target_object, @load_type, N'RUNNING');

    SET @step_id = SCOPE_IDENTITY();
END;
GO

-- =============================================================================
-- audit.usp_step_end
-- =============================================================================
CREATE OR ALTER PROCEDURE audit.usp_step_end
    @step_id       BIGINT,
    @status        NVARCHAR(20),
    @rows_read     BIGINT = 0,
    @rows_inserted BIGINT = 0,
    @rows_updated  BIGINT = 0,
    @rows_deleted  BIGINT = 0,
    @rows_rejected BIGINT = 0,
    @message       NVARCHAR(4000) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE audit.etl_step_log
    SET end_time      = SYSDATETIME(),
        status        = @status,
        rows_read     = ISNULL(@rows_read, 0),
        rows_inserted = ISNULL(@rows_inserted, 0),
        rows_updated  = ISNULL(@rows_updated, 0),
        rows_deleted  = ISNULL(@rows_deleted, 0),
        rows_rejected = ISNULL(@rows_rejected, 0),
        message       = @message
    WHERE step_id = @step_id;
END;
GO

-- =============================================================================
-- audit.usp_log_error
-- Must be called from inside a CATCH block: the ERROR_*() functions keep their
-- values inside procedures that are called from the CATCH block.
-- =============================================================================
CREATE OR ALTER PROCEDURE audit.usp_log_error
    @batch_id       INT           = NULL,
    @step_id        BIGINT        = NULL,
    @procedure_name NVARCHAR(256) = NULL,
    @object_name    NVARCHAR(256) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO audit.etl_error_log (
        batch_id, step_id, procedure_name, object_name,
        error_number, error_severity, error_state, error_line, error_procedure, error_message
    )
    VALUES (
        @batch_id, @step_id, @procedure_name, @object_name,
        ERROR_NUMBER(), ERROR_SEVERITY(), ERROR_STATE(), ERROR_LINE(), ERROR_PROCEDURE(), ERROR_MESSAGE()
    );
END;
GO

-- =============================================================================
-- etl.usp_get_watermark
-- =============================================================================
CREATE OR ALTER PROCEDURE etl.usp_get_watermark
    @watermark_name NVARCHAR(200),
    @value_binary   VARBINARY(32) = NULL OUTPUT,
    @value_datetime DATETIME2(7)  = NULL OUTPUT,
    @value_bigint   BIGINT        = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT @value_binary   = value_binary,
           @value_datetime = value_datetime,
           @value_bigint   = value_bigint
    FROM audit.etl_watermark
    WHERE watermark_name = @watermark_name;
END;
GO

-- =============================================================================
-- etl.usp_set_watermark
-- Call inside the same transaction that writes the data, so the watermark only
-- moves forward when the data is committed.
-- =============================================================================
CREATE OR ALTER PROCEDURE etl.usp_set_watermark
    @watermark_name NVARCHAR(200),
    @watermark_type NVARCHAR(20),
    @value_binary   VARBINARY(32) = NULL,
    @value_datetime DATETIME2(7)  = NULL,
    @value_bigint   BIGINT        = NULL,
    @batch_id       INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE audit.etl_watermark
    SET watermark_type = @watermark_type,
        value_binary   = @value_binary,
        value_datetime = @value_datetime,
        value_bigint   = @value_bigint,
        last_batch_id  = @batch_id,
        updated_at     = SYSDATETIME()
    WHERE watermark_name = @watermark_name;

    IF @@ROWCOUNT = 0
        INSERT INTO audit.etl_watermark (watermark_name, watermark_type, value_binary, value_datetime, value_bigint, last_batch_id)
        VALUES (@watermark_name, @watermark_type, @value_binary, @value_datetime, @value_bigint, @batch_id);
END;
GO

-- =============================================================================
-- etl.usp_check_fault_injection
-- Testing hook. Production value of the setting is NULL, so this does nothing.
-- Points used by the framework:
--   INGESTION:<source table>   BRONZE:<bronze table>   SILVER:<silver table>
--   GOLD:<gold table>
-- =============================================================================
CREATE OR ALTER PROCEDURE etl.usp_check_fault_injection
    @point NVARCHAR(300)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @configured NVARCHAR(4000) = audit.fn_get_setting(N'fault_injection_point');
    DECLARE @msg NVARCHAR(2048);

    IF @configured IS NOT NULL AND @configured = @point
    BEGIN
        SET @msg = N'Injected test failure at point ' + @point + N'.';
        THROW 50900, @msg, 1;
    END;
END;
GO

PRINT 'Audit helper procedures ready.';
GO
