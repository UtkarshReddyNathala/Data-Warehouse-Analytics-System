/*
===============================================================================
Stored Procedure: etl.usp_run_pipeline  (Master ETL Pipeline)
===============================================================================
In short:
    Creates etl.usp_run_pipeline, the one procedure that runs the whole pipeline
    from start to end. It loads the files, captures changes, fills Bronze,
    Silver and Gold, and checks the data quality, stopping at the first serious
    problem.

Script Purpose:
    Runs the complete warehouse pipeline in dependency order and stops as soon
    as a critical stage fails:

        0. Lock         only one pipeline run at a time (sp_getapplock)
        1. Validate     audit.etl_config (etl.usp_validate_config)
        2. Ingestion    CSV files -> landing -> source tables (checksums)
        3. CDC sync     wait until CDC has captured the latest source changes
        4. Bronze       CDC / INCREMENTAL / FULL extraction (metadata-driven)
        5. Silver       cleaning, deduplication, incremental MERGE (metadata-driven)
        6. Silver DQ    data quality rules - CRITICAL failures stop the run here,
                        so Gold is only loaded from validated data
        7. Gold         dimensions first (SCD1/SCD2), then facts
        8. Gold DQ      dimension history, referential integrity, reconciliation
        9. Audit        batch closed as SUCCESS / SUCCESS_WITH_WARNINGS / FAILED
                        SUCCESS_WITH_WARNINGS when any of these is above zero
                        (stored separately on audit.etl_batch):
                          failed_step_count  non-critical table failures
                          dq_warning_count   WARNING-level DQ results
                          dq_critical_count  CRITICAL DQ failures that did not
                                             stop the run (dq_stop_on_critical = 0)

    A failure is recorded in audit.etl_batch, audit.etl_step_log and
    audit.etl_error_log and then RE-THROWN, so a caller (SQL Agent job, test
    script, orchestration tool) never sees a failed run as successful.

Parameters:
    @run_file_ingestion  1 = check the CSV files for changes (default)
    @force_file_reload   1 = reload files even if their checksum is unchanged
    @force_cdc_resync    1 = take full snapshots instead of incremental extracts
    @return_summary      1 = return the step summary as a result set
    @batch_id            OUTPUT batch id

Usage:
    EXEC etl.usp_run_pipeline;
    Then run scripts/monitoring/etl_monitoring_dashboard.sql
===============================================================================
*/

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

USE DataWarehouse;
GO

CREATE OR ALTER PROCEDURE etl.usp_run_pipeline
    @run_file_ingestion BIT = 1,
    @force_file_reload  BIT = 0,
    @force_cdc_resync   BIT = 0,
    @return_summary     BIT = 1,
    @batch_id           INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @lock INT, @step_id BIGINT, @w INT = 0, @critical INT = 0, @dq_warnings INT = 0;
    -- Three separate counters, all stored on audit.etl_batch
    DECLARE @failed_steps INT = 0,      -- non-critical table failures
            @dq_warning_total INT = 0,  -- WARNING-level data quality results (Silver + Gold)
            @dq_critical_total INT = 0; -- CRITICAL failures that did not stop the run (dq_stop_on_critical = 0)
    DECLARE @msg NVARCHAR(4000), @params NVARCHAR(1000), @final_status NVARCHAR(30);
    DECLARE @stop_on_critical BIT = ISNULL(TRY_CAST(audit.fn_get_setting(N'dq_stop_on_critical') AS BIT), 1);
    DECLARE @start DATETIME2(3) = SYSDATETIME();

    SET @batch_id = NULL;

    -- 0. Only one run at a time ---------------------------------------------------
    EXEC @lock = sys.sp_getapplock @Resource = N'DWH_MASTER_PIPELINE', @LockMode = N'Exclusive',
                                   @LockOwner = N'Session', @LockTimeout = 0;
    IF @lock < 0
        THROW 50600, 'Another pipeline run is already in progress.', 1;

    SET @params = CONCAT(N'run_file_ingestion=', @run_file_ingestion, N'; force_file_reload=', @force_file_reload,
                         N'; force_cdc_resync=', @force_cdc_resync);

    BEGIN TRY
        EXEC audit.usp_start_batch @pipeline_name = N'DWH_MASTER_PIPELINE', @run_parameters = @params, @batch_id = @batch_id OUTPUT;

        PRINT '================================================';
        PRINT 'MASTER ETL PIPELINE | BATCH ID ' + CAST(@batch_id AS NVARCHAR(10));
        PRINT '================================================';

        -- 1. Validate configuration -----------------------------------------------
        EXEC audit.usp_step_start @batch_id, N'PIPELINE', N'Validate metadata configuration', N'audit.etl_config', NULL, NULL, @step_id OUTPUT;
        EXEC etl.usp_validate_config @raise_error = 1;
        EXEC audit.usp_step_end @step_id, N'SUCCESS';

        -- 2. File ingestion ------------------------------------------------------------
        IF @run_file_ingestion = 1
        BEGIN
            PRINT '--- STEP 2: FILE INGESTION (CSV -> source)';
            EXEC etl.usp_run_metadata_driven_load @batch_id = @batch_id, @stage = N'INGESTION',
                 @force_reload = @force_file_reload, @warning_count = @w OUTPUT;
            SET @failed_steps += @w;
        END;

        -- 3. CDC capture synchronisation -------------------------------------------
        IF EXISTS (SELECT 1 FROM audit.etl_config WHERE is_active = 1 AND load_type = N'CDC')
        BEGIN
            PRINT '--- STEP 3: WAIT FOR CDC CAPTURE';
            EXEC audit.usp_step_start @batch_id, N'CDC', N'Wait for CDC capture to reach the latest changes', N'transaction log', N'cdc change tables', N'CDC', @step_id OUTPUT;
            EXEC etl.usp_cdc_sync_capture;
            EXEC audit.usp_step_end @step_id, N'SUCCESS';
        END;

        -- 4. Bronze ------------------------------------------------------------------
        PRINT '--- STEP 4: BRONZE (source -> bronze)';
        EXEC etl.usp_run_metadata_driven_load @batch_id = @batch_id, @stage = N'BRONZE',
             @force_resync = @force_cdc_resync, @warning_count = @w OUTPUT;
        SET @failed_steps += @w;

        -- 5. Silver ------------------------------------------------------------------
        PRINT '--- STEP 5: SILVER (bronze -> silver)';
        EXEC etl.usp_run_metadata_driven_load @batch_id = @batch_id, @stage = N'SILVER', @warning_count = @w OUTPUT;
        SET @failed_steps += @w;

        -- 6. Silver data quality --------------------------------------------------
        PRINT '--- STEP 6: SILVER DATA QUALITY';
        EXEC audit.usp_step_start @batch_id, N'DATA_QUALITY', N'Silver data quality checks', N'audit.dq_rule', N'audit.dq_result', NULL, @step_id OUTPUT;
        EXEC etl.usp_run_dq_checks @batch_id = @batch_id, @layer = N'SILVER', @critical_failures = @critical OUTPUT, @warnings = @dq_warnings OUTPUT;
        SET @dq_warning_total += @dq_warnings;
        SET @msg = CONCAT(N'Critical failures: ', @critical, N', warnings: ', @dq_warnings, N'.');

        IF @critical > 0 AND @stop_on_critical = 1
        BEGIN
            EXEC audit.usp_step_end @step_id, N'FAILED', @rows_rejected = @critical, @message = @msg;
            SET @msg = N'Critical Silver data quality rules failed (' + CAST(@critical AS NVARCHAR(10))
                     + N'). Gold was not loaded. See audit.dq_result for batch ' + CAST(@batch_id AS NVARCHAR(10)) + N'.';
            THROW 50601, @msg, 1;
        END;
        SET @dq_critical_total += @critical;   -- only reached when dq_stop_on_critical = 0
        EXEC audit.usp_step_end @step_id, N'SUCCESS', @message = @msg;

        -- 7. Gold ---------------------------------------------------------------------
        PRINT '--- STEP 7: GOLD (dimensions, then facts)';
        EXEC gold.load_gold @batch_id = @batch_id;

        -- 8. Gold data quality ------------------------------------------------------
        PRINT '--- STEP 8: GOLD DATA QUALITY';
        EXEC audit.usp_step_start @batch_id, N'DATA_QUALITY', N'Gold data quality checks', N'audit.dq_rule', N'audit.dq_result', NULL, @step_id OUTPUT;
        EXEC etl.usp_run_dq_checks @batch_id = @batch_id, @layer = N'GOLD', @critical_failures = @critical OUTPUT, @warnings = @dq_warnings OUTPUT;
        SET @dq_warning_total += @dq_warnings;
        SET @msg = CONCAT(N'Critical failures: ', @critical, N', warnings: ', @dq_warnings, N'.');

        IF @critical > 0 AND @stop_on_critical = 1
        BEGIN
            EXEC audit.usp_step_end @step_id, N'FAILED', @rows_rejected = @critical, @message = @msg;
            SET @msg = N'Critical Gold data quality rules failed (' + CAST(@critical AS NVARCHAR(10))
                     + N'). See audit.dq_result for batch ' + CAST(@batch_id AS NVARCHAR(10)) + N'.';
            THROW 50602, @msg, 1;
        END;
        SET @dq_critical_total += @critical;
        EXEC audit.usp_step_end @step_id, N'SUCCESS', @message = @msg;

        -- 9. Close the batch ----------------------------------------------------------
        SET @final_status = CASE WHEN @failed_steps + @dq_warning_total + @dq_critical_total > 0
                                 THEN N'SUCCESS_WITH_WARNINGS' ELSE N'SUCCESS' END;
        EXEC audit.usp_end_batch @batch_id = @batch_id, @status = @final_status,
             @failed_step_count = @failed_steps, @dq_warning_count = @dq_warning_total,
             @dq_critical_count = @dq_critical_total;

        EXEC sys.sp_releaseapplock @Resource = N'DWH_MASTER_PIPELINE', @LockOwner = N'Session';

        PRINT '================================================';
        PRINT 'PIPELINE ' + @final_status + ' in ' + CAST(DATEDIFF(SECOND, @start, SYSDATETIME()) AS NVARCHAR(10)) + ' seconds';
        PRINT 'Run scripts/monitoring/etl_monitoring_dashboard.sql for details.';
        PRINT '================================================';
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;

        SET @msg = LEFT(ERROR_MESSAGE(), 4000);

        IF @batch_id IS NOT NULL
        BEGIN
            -- Log the error unless the failing step already logged it
            IF NOT EXISTS (SELECT 1 FROM audit.etl_error_log WHERE batch_id = @batch_id AND error_message = @msg)
                EXEC audit.usp_log_error @batch_id = @batch_id, @step_id = @step_id, @procedure_name = N'etl.usp_run_pipeline';

            UPDATE audit.etl_step_log
            SET status = N'FAILED', end_time = SYSDATETIME(), message = ISNULL(message, @msg)
            WHERE batch_id = @batch_id AND status = N'RUNNING';

            EXEC audit.usp_end_batch @batch_id = @batch_id, @status = N'FAILED', @error_message = @msg,
                 @failed_step_count = @failed_steps, @dq_warning_count = @dq_warning_total,
                 @dq_critical_count = @critical;
        END;

        EXEC sys.sp_releaseapplock @Resource = N'DWH_MASTER_PIPELINE', @LockOwner = N'Session';

        PRINT '================================================';
        PRINT 'PIPELINE FAILED (batch ' + ISNULL(CAST(@batch_id AS NVARCHAR(10)), N'-') + '): ' + @msg;
        PRINT '================================================';

        THROW;   -- never report a failed run as successful
    END CATCH;

    IF @return_summary = 1
        SELECT stage, step_name, load_type, status, rows_read, rows_inserted, rows_updated,
               rows_deleted, rows_rejected, duration_ms, message
        FROM audit.etl_step_log
        WHERE batch_id = @batch_id
        ORDER BY step_id;
END;
GO
