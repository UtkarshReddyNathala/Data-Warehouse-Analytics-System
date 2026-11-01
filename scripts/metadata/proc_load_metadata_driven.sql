/*
===============================================================================
Stored Procedure: etl.usp_run_metadata_driven_load
===============================================================================
In short:
    The loader that reads audit.etl_config and processes each table in order:
    load the file, extract the changes to Bronze, then clean them into Silver.
    One table failing is logged, and only stops the run if that table is marked
    as critical.

Script Purpose:
    The single loading mechanism for the Ingestion, Bronze and Silver stages.

    It reads the active rows of audit.etl_config in load_priority order and,
    for each table:
      INGESTION -> etl.usp_ingest_source_file    (CSV -> landing -> source)
      BRONZE    -> bronze.usp_extract_table      (CDC / INCREMENTAL / FULL)
      SILVER    -> the configured silver_procedure (called with dynamic SQL)

    Every table gets its own row in audit.etl_step_log with row counts.
    Failures are written to audit.etl_error_log. A failure of a table marked
    is_critical = 1 stops the pipeline (the error is re-thrown); a failure of a
    non-critical table is logged and counted as a warning.

    Adding, disabling or re-ordering a table, or changing its load type, is a
    change to audit.etl_config only - no code change.

Parameters:
    @batch_id       Pipeline batch.
    @stage          INGESTION / BRONZE / SILVER.
    @config_id      Optional: run a single configuration row.
    @force_reload   INGESTION: reload files even if their checksum is unchanged.
    @force_resync   BRONZE: take a full snapshot instead of an incremental extract.
    @warning_count  OUTPUT number of non-critical failures.
===============================================================================
*/

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

USE DataWarehouse;
GO

-- The previous, unused full-load procedure is replaced by this framework.
IF OBJECT_ID(N'silver.load_metadata_driven', N'P') IS NOT NULL
    DROP PROCEDURE silver.load_metadata_driven;
GO

CREATE OR ALTER PROCEDURE etl.usp_run_metadata_driven_load
    @batch_id      INT,
    @stage         NVARCHAR(20),
    @config_id     INT = NULL,
    @force_reload  BIT = 0,
    @force_resync  BIT = 0,
    @warning_count INT = 0 OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SET @warning_count = 0;

    IF @stage NOT IN (N'INGESTION', N'BRONZE', N'SILVER')
        THROW 50500, 'etl.usp_run_metadata_driven_load: @stage must be INGESTION, BRONZE or SILVER.', 1;

    DECLARE @todo TABLE (
        config_id      INT PRIMARY KEY,
        load_priority  INT,
        is_critical    BIT,
        load_type      NVARCHAR(20),
        source_name    NVARCHAR(300),
        target_name    NVARCHAR(300),
        silver_name    NVARCHAR(300),
        silver_proc    NVARCHAR(300),
        file_path      NVARCHAR(400)
    );

    INSERT INTO @todo
    SELECT config_id, load_priority, is_critical, load_type,
           source_schema + N'.' + source_table,
           target_schema + N'.' + target_table,
           silver_schema + N'.' + silver_table,
           QUOTENAME(silver_schema) + N'.' + QUOTENAME(silver_procedure),
           source_file_path
    FROM audit.etl_config
    WHERE ((@config_id IS NULL AND is_active = 1) OR config_id = @config_id)
      AND (@stage <> N'INGESTION' OR source_file_path IS NOT NULL);

    DECLARE @cid INT, @critical BIT, @load_type NVARCHAR(20), @src NVARCHAR(300), @tgt NVARCHAR(300),
            @silver NVARCHAR(300), @silver_proc NVARCHAR(300), @file NVARCHAR(400);
    DECLARE @step_id BIGINT, @step_name NVARCHAR(200), @step_source NVARCHAR(300), @step_target NVARCHAR(300);
    DECLARE @r BIGINT, @i BIGINT, @u BIGINT, @d BIGINT, @rej BIGINT, @msg NVARCHAR(1000), @file_status NVARCHAR(20);
    DECLARE @sql NVARCHAR(MAX), @err NVARCHAR(4000), @step_status NVARCHAR(20);

    WHILE EXISTS (SELECT 1 FROM @todo)
    BEGIN
        SELECT TOP (1)
            @cid = config_id, @critical = is_critical, @load_type = load_type, @src = source_name,
            @tgt = target_name, @silver = silver_name, @silver_proc = silver_proc, @file = file_path
        FROM @todo
        ORDER BY load_priority, config_id;

        SELECT @r = 0, @i = 0, @u = 0, @d = 0, @rej = 0, @msg = NULL, @file_status = NULL, @step_id = NULL;

        SELECT @step_name   = @stage + N' ' + CASE @stage WHEN N'INGESTION' THEN @src WHEN N'BRONZE' THEN @tgt ELSE @silver END,
               @step_source = CASE @stage WHEN N'INGESTION' THEN @file WHEN N'BRONZE' THEN @src ELSE @tgt END,
               @step_target = CASE @stage WHEN N'INGESTION' THEN @src  WHEN N'BRONZE' THEN @tgt ELSE @silver END;

        EXEC audit.usp_step_start @batch_id, @stage, @step_name, @step_source, @step_target,
             @load_type, @step_id OUTPUT;

        BEGIN TRY
            IF @stage = N'INGESTION'
            BEGIN
                EXEC etl.usp_ingest_source_file
                     @batch_id = @batch_id, @config_id = @cid, @force_reload = @force_reload,
                     @rows_read = @r OUTPUT, @rows_inserted = @i OUTPUT, @rows_updated = @u OUTPUT,
                     @rows_deleted = @d OUTPUT, @rows_rejected = @rej OUTPUT, @status = @file_status OUTPUT,
                     @message = @msg OUTPUT;

                IF @file_status = N'SKIPPED_DUPLICATE'
                    SET @msg = N'File unchanged since the last successful load (checksum match).';
            END
            ELSE IF @stage = N'BRONZE'
            BEGIN
                EXEC bronze.usp_extract_table
                     @batch_id = @batch_id, @config_id = @cid, @force_resync = @force_resync,
                     @rows_read = @r OUTPUT, @rows_inserted = @i OUTPUT, @message = @msg OUTPUT;
            END
            ELSE   -- SILVER: call the configured procedure
            BEGIN
                IF OBJECT_ID(@silver_proc, N'P') IS NULL
                BEGIN
                    SET @err = N'Configured Silver procedure ' + @silver_proc + N' does not exist.';
                    THROW 50501, @err, 1;
                END;

                SET @sql = N'EXEC ' + @silver_proc + N' @batch_id = @b, @rows_read = @r OUTPUT, @rows_inserted = @i OUTPUT, '
                         + N'@rows_updated = @u OUTPUT, @rows_deleted = @d OUTPUT, @rows_rejected = @rej OUTPUT, @message = @msg OUTPUT;';

                EXEC sys.sp_executesql @sql,
                     N'@b INT, @r BIGINT OUTPUT, @i BIGINT OUTPUT, @u BIGINT OUTPUT, @d BIGINT OUTPUT, @rej BIGINT OUTPUT, @msg NVARCHAR(1000) OUTPUT',
                     @b = @batch_id, @r = @r OUTPUT, @i = @i OUTPUT, @u = @u OUTPUT, @d = @d OUTPUT, @rej = @rej OUTPUT, @msg = @msg OUTPUT;
            END;

            SET @step_status = CASE WHEN @file_status = N'SKIPPED_DUPLICATE' THEN N'SKIPPED' ELSE N'SUCCESS' END;

            EXEC audit.usp_step_end @step_id,
                 @status = @step_status,
                 @rows_read = @r, @rows_inserted = @i, @rows_updated = @u, @rows_deleted = @d,
                 @rows_rejected = @rej, @message = @msg;
        END TRY
        BEGIN CATCH
            IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;

            SET @err = LEFT(ERROR_MESSAGE(), 4000);
            EXEC audit.usp_log_error @batch_id = @batch_id, @step_id = @step_id,
                 @procedure_name = N'etl.usp_run_metadata_driven_load', @object_name = @step_target;
            EXEC audit.usp_step_end @step_id, N'FAILED', @message = @err;

            PRINT '!! ' + @step_name + ' FAILED: ' + @err;

            IF @critical = 1
                THROW;                     -- stop the pipeline

            SET @warning_count += 1;       -- non-critical: continue with the next table
        END CATCH;

        DELETE FROM @todo WHERE config_id = @cid;
    END;
END;
GO
