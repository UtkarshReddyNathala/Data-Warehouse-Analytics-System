/*
===============================================================================
Stored Procedure: bronze.usp_extract_table  (Source -> Bronze, metadata-driven)
===============================================================================
In short:
    Copies the new changes of one source table into Bronze. Depending on the
    settings it uses CDC, a watermark (only rows changed since last time) or a
    full copy.

Script Purpose:
    Extracts the changes of ONE configured source table into its Bronze table.
    The extraction strategy comes from audit.etl_config.load_type:

    CDC
      - Reads cdc.fn_cdc_get_all_changes_<capture_instance> between the last
        processed LSN (audit.cdc_control) and the current maximum LSN.
      - Captures inserts (I), updates (B = before image, U = after image) and
        deletes (D), keeping __$start_lsn and __$seqval.
      - Initial load, forced re-sync, or a CDC retention gap (the saved LSN is
        older than the oldest LSN still available) -> a controlled full
        snapshot (S rows) is taken instead of silently skipping changes.
        The upper LSN is read BEFORE the snapshot, so changes that happen
        during the snapshot are replayed later (Silver applies them
        idempotently).

    INCREMENTAL
      - Watermark column (ROWVERSION recommended, or a date/time column).
      - Upper bound = MIN_ACTIVE_ROWVERSION() so rows of transactions that are
        still open are never skipped.
      - Soft-deleted source rows (is_deleted = 1) become D rows.
      - First run = full snapshot.

    FULL
      - Takes a snapshot only when the table content changed: a SHA2_256
        fingerprint of the whole table is compared with the previous one.

    The Bronze insert and the watermark/LSN update are committed in ONE
    transaction: a failed run never moves the watermark, and a re-run never
    creates duplicate Bronze rows.

Parameters:
    @batch_id, @config_id, @force_resync (CDC/FULL/INCREMENTAL: take a snapshot)
    OUTPUT: @rows_read, @rows_inserted, @message
===============================================================================
*/

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

USE DataWarehouse;
GO

CREATE OR ALTER PROCEDURE bronze.usp_extract_table
    @batch_id      INT,
    @config_id     INT,
    @force_resync  BIT = 0,
    @rows_read     BIGINT = 0 OUTPUT,
    @rows_inserted BIGINT = 0 OUTPUT,
    @message       NVARCHAR(1000) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SELECT @rows_read = 0, @rows_inserted = 0, @message = NULL;

    DECLARE @src_schema SYSNAME, @src_table SYSNAME, @tgt_schema SYSNAME, @tgt_table SYSNAME,
            @load_type NVARCHAR(20), @wm_col SYSNAME, @ci SYSNAME, @pk_list NVARCHAR(400);

    SELECT @src_schema = source_schema, @src_table = source_table,
           @tgt_schema = target_schema, @tgt_table = target_table,
           @load_type  = load_type,     @wm_col    = watermark_column,
           @ci         = capture_instance, @pk_list = primary_key_columns
    FROM audit.etl_config
    WHERE config_id = @config_id;

    IF @src_table IS NULL
        THROW 50400, 'bronze.usp_extract_table: configuration row not found.', 1;

    DECLARE @src2 NVARCHAR(300) = QUOTENAME(@src_schema) + N'.' + QUOTENAME(@src_table);
    DECLARE @tgt2 NVARCHAR(300) = QUOTENAME(@tgt_schema) + N'.' + QUOTENAME(@tgt_table);
    DECLARE @src_name NVARCHAR(300) = @src_schema + N'.' + @src_table;
    DECLARE @tgt_name NVARCHAR(300) = @tgt_schema + N'.' + @tgt_table;
    -- One watermark per load type, so switching a table between FULL and
    -- INCREMENTAL in audit.etl_config never mixes a hash with a rowversion.
    DECLARE @wm_name NVARCHAR(200) = N'bronze:' + @src_name + N':' + @load_type;
    DECLARE @sql NVARCHAR(MAX), @cols NVARCHAR(MAX), @c_cols NVARCHAR(MAX), @pk_cols NVARCHAR(MAX);
    DECLARE @has_soft_delete BIT = CASE WHEN COL_LENGTH(@src2, N'is_deleted') IS NOT NULL
                                         AND COL_LENGTH(@tgt2, N'is_deleted') IS NOT NULL THEN 1 ELSE 0 END;
    DECLARE @fault_point NVARCHAR(300) = N'BRONZE:' + @tgt_name;

    -- -------------------------------------------------------------------------
    -- Columns shared by source and Bronze (business columns only)
    -- -------------------------------------------------------------------------
    SELECT @cols   = STRING_AGG(CAST(QUOTENAME(s.name) AS NVARCHAR(MAX)), N', ') WITHIN GROUP (ORDER BY s.column_id),
           @c_cols = STRING_AGG(CAST(N'c.' + QUOTENAME(s.name) AS NVARCHAR(MAX)), N', ') WITHIN GROUP (ORDER BY s.column_id)
    FROM sys.columns AS s
    JOIN sys.types   AS ty ON ty.user_type_id = s.user_type_id
    WHERE s.object_id = OBJECT_ID(@src2)
      AND ty.name <> N'timestamp'
      AND s.is_computed = 0
      AND COL_LENGTH(@tgt2, s.name) IS NOT NULL
      AND s.name NOT IN (N'bronze_id', N'batch_id', N'load_type', N'change_operation', N'is_full_snapshot',
                         N'cdc_start_lsn', N'cdc_seqval', N'source_file_id', N'extracted_at');

    SELECT @pk_cols = STRING_AGG(CAST(QUOTENAME(TRIM(value)) AS NVARCHAR(MAX)), N', ')
    FROM STRING_SPLIT(@pk_list, N',');

    IF @cols IS NULL
        THROW 50401, 'No matching columns between the source and Bronze tables.', 1;

    -- Lineage: the last successfully ingested file for this source table
    DECLARE @source_file_id INT =
        (SELECT TOP (1) file_id FROM audit.file_ingestion_log
         WHERE config_id = @config_id AND status = N'SUCCESS' ORDER BY file_id DESC);

    -- Shared snapshot statement (initial load, FULL load, CDC re-sync)
    DECLARE @snapshot_sql NVARCHAR(MAX) =
          N'INSERT INTO ' + @tgt2 + N' (batch_id, load_type, change_operation, is_full_snapshot, cdc_start_lsn, cdc_seqval, source_file_id, ' + @cols + N') '
        + N'SELECT @batch_id, @load_type, '
        + CASE WHEN @has_soft_delete = 1 THEN N'CASE WHEN c.is_deleted = 1 THEN ''D'' ELSE ''S'' END' ELSE N'''S''' END
        + N', 1, NULL, NULL, @file_id, ' + @c_cols + N' FROM ' + @src2 + N' AS c ';

    BEGIN TRY
        -- =====================================================================
        -- CDC
        -- =====================================================================
        IF @load_type = N'CDC'
        BEGIN
            DECLARE @last_lsn BINARY(10), @min_lsn BINARY(10), @max_lsn BINARY(10), @from_lsn BINARY(10);
            DECLARE @resync_reason NVARCHAR(400);

            IF NOT EXISTS (SELECT 1 FROM audit.cdc_control WHERE config_id = @config_id)
                THROW 50402, 'Table is not registered in audit.cdc_control. Run EXEC etl.usp_enable_cdc.', 1;

            SELECT @last_lsn = last_processed_lsn FROM audit.cdc_control WHERE config_id = @config_id;

            SET @min_lsn = sys.fn_cdc_get_min_lsn(@ci);
            SET @max_lsn = sys.fn_cdc_get_max_lsn();

            IF @min_lsn IS NULL OR @min_lsn = 0x00000000000000000000
                THROW 50403, 'CDC capture instance is missing or invalid. Run EXEC etl.usp_enable_cdc.', 1;
            IF @max_lsn IS NULL OR @max_lsn = 0x00000000000000000000
                THROW 50404, 'CDC has not captured any LSN yet. Check that the capture job is running.', 1;

            SET @resync_reason = CASE
                WHEN @force_resync = 1  THEN N'Forced re-synchronisation.'
                WHEN @last_lsn IS NULL  THEN N'Initial load: no LSN processed yet.'
                WHEN sys.fn_cdc_increment_lsn(@last_lsn) < @min_lsn
                    THEN N'CDC retention gap: next LSN ' + CONVERT(NVARCHAR(30), sys.fn_cdc_increment_lsn(@last_lsn), 1)
                       + N' is older than the oldest available LSN ' + CONVERT(NVARCHAR(30), @min_lsn, 1) + N'.'
                ELSE NULL END;

            UPDATE audit.cdc_control
            SET status = N'PROCESSING', current_batch_id = @batch_id, last_error = NULL
            WHERE config_id = @config_id;

            BEGIN TRANSACTION;

                IF @resync_reason IS NOT NULL
                BEGIN
                    -- Controlled re-synchronisation: full snapshot, then continue from @max_lsn
                    SET @sql = @snapshot_sql + N'ORDER BY ' + @pk_cols + N';';
                    SET @sql += N' SET @n = @@ROWCOUNT;';   -- count inside the dynamic batch
                    EXEC sys.sp_executesql @sql, N'@batch_id INT, @load_type NVARCHAR(20), @file_id INT, @n BIGINT OUTPUT',
                         @batch_id = @batch_id, @load_type = @load_type, @file_id = @source_file_id, @n = @rows_inserted OUTPUT;

                    UPDATE audit.cdc_control
                    SET last_processed_lsn = @max_lsn,
                        last_resync_at     = SYSDATETIME(),
                        last_resync_reason = @resync_reason
                    WHERE config_id = @config_id;

                    SET @message = N'Snapshot taken. ' + @resync_reason + N' Continuing from LSN ' + CONVERT(NVARCHAR(30), @max_lsn, 1) + N'.';
                END
                ELSE
                BEGIN
                    SET @from_lsn = sys.fn_cdc_increment_lsn(@last_lsn);

                    IF @from_lsn <= @max_lsn
                    BEGIN
                        SET @sql = N'INSERT INTO ' + @tgt2 + N' (batch_id, load_type, change_operation, is_full_snapshot, cdc_start_lsn, cdc_seqval, source_file_id, ' + @cols + N') '
                                 + N'SELECT @batch_id, N''CDC'', '
                                 + N'CASE c.__$operation WHEN 1 THEN ''D'' WHEN 2 THEN ''I'' WHEN 3 THEN ''B'' WHEN 4 THEN ''U'' END, '
                                 + N'0, c.__$start_lsn, c.__$seqval, @file_id, ' + @c_cols + N' '
                                 + N'FROM cdc.' + QUOTENAME(N'fn_cdc_get_all_changes_' + @ci) + N'(@from_lsn, @to_lsn, N''all update old'') AS c '
                                 + N'ORDER BY c.__$start_lsn, c.__$seqval, c.__$operation;';

                        SET @sql += N' SET @n = @@ROWCOUNT;';   -- count inside the dynamic batch
                        EXEC sys.sp_executesql @sql, N'@batch_id INT, @file_id INT, @from_lsn BINARY(10), @to_lsn BINARY(10), @n BIGINT OUTPUT',
                             @batch_id = @batch_id, @file_id = @source_file_id, @from_lsn = @from_lsn, @to_lsn = @max_lsn, @n = @rows_inserted OUTPUT;

                        UPDATE audit.cdc_control
                        SET last_processed_lsn = @max_lsn
                        WHERE config_id = @config_id;

                        SET @message = N'CDC LSN range ' + CONVERT(NVARCHAR(30), @from_lsn, 1) + N' - ' + CONVERT(NVARCHAR(30), @max_lsn, 1) + N'.';
                    END
                    ELSE
                        SET @message = N'No new CDC changes after LSN ' + CONVERT(NVARCHAR(30), @last_lsn, 1) + N'.';
                END;

                EXEC etl.usp_check_fault_injection @point = @fault_point;

                UPDATE audit.cdc_control
                SET status = N'IDLE', last_processed_at = SYSDATETIME()
                WHERE config_id = @config_id;

            COMMIT TRANSACTION;
        END

        -- =====================================================================
        -- INCREMENTAL (watermark)
        -- =====================================================================
        ELSE IF @load_type = N'INCREMENTAL'
        BEGIN
            DECLARE @wm_type SYSNAME =
                (SELECT TYPE_NAME(system_type_id) FROM sys.columns
                 WHERE object_id = OBJECT_ID(@src2) AND name = @wm_col);
            DECLARE @lo_bin VARBINARY(32), @lo_dt DATETIME2(7), @hi_bin BINARY(8), @hi_dt DATETIME2(7);
            DECLARE @first_run BIT = CASE WHEN EXISTS (SELECT 1 FROM audit.etl_watermark WHERE watermark_name = @wm_name) THEN 0 ELSE 1 END;
            DECLARE @op_expr NVARCHAR(200) = CASE WHEN @has_soft_delete = 1
                                                  THEN N'CASE WHEN c.is_deleted = 1 THEN ''D'' ELSE ''U'' END'
                                                  ELSE N'''U''' END;

            IF @wm_type IS NULL
                THROW 50405, 'Watermark column not found in the source table.', 1;

            IF @force_resync = 1 SET @first_run = 1;

            EXEC etl.usp_get_watermark @watermark_name = @wm_name, @value_binary = @lo_bin OUTPUT, @value_datetime = @lo_dt OUTPUT;

            IF @wm_type = N'timestamp'   -- ROWVERSION
            BEGIN
                SET @hi_bin = CAST(MIN_ACTIVE_ROWVERSION() AS BINARY(8));

                IF @first_run = 1
                    SET @sql = @snapshot_sql + N'WHERE c.' + QUOTENAME(@wm_col) + N' < @hi ORDER BY c.' + QUOTENAME(@wm_col) + N';';
                ELSE
                    SET @sql = N'INSERT INTO ' + @tgt2 + N' (batch_id, load_type, change_operation, is_full_snapshot, cdc_start_lsn, cdc_seqval, source_file_id, ' + @cols + N') '
                             + N'SELECT @batch_id, @load_type, ' + @op_expr + N', 0, NULL, NULL, @file_id, ' + @c_cols + N' '
                             + N'FROM ' + @src2 + N' AS c '
                             + N'WHERE c.' + QUOTENAME(@wm_col) + N' >= @lo AND c.' + QUOTENAME(@wm_col) + N' < @hi '
                             + N'ORDER BY c.' + QUOTENAME(@wm_col) + N';';

                BEGIN TRANSACTION;
                    SET @sql += N' SET @n = @@ROWCOUNT;';   -- count inside the dynamic batch
                    EXEC sys.sp_executesql @sql, N'@batch_id INT, @load_type NVARCHAR(20), @file_id INT, @lo BINARY(8), @hi BINARY(8), @n BIGINT OUTPUT',
                         @batch_id = @batch_id, @load_type = @load_type, @file_id = @source_file_id,
                         @lo = @lo_bin, @hi = @hi_bin, @n = @rows_inserted OUTPUT;

                    EXEC etl.usp_check_fault_injection @point = @fault_point;

                    EXEC etl.usp_set_watermark @watermark_name = @wm_name, @watermark_type = N'ROWVERSION',
                         @value_binary = @hi_bin, @batch_id = @batch_id;
                COMMIT TRANSACTION;

                SET @message = CASE WHEN @first_run = 1 THEN N'Initial snapshot' ELSE N'Incremental' END
                             + N' up to rowversion ' + CONVERT(NVARCHAR(30), @hi_bin, 1) + N' (exclusive).';
            END
            ELSE                        -- date/time watermark
            BEGIN
                SET @hi_dt = SYSDATETIME();

                IF @first_run = 1
                    SET @sql = @snapshot_sql + N'WHERE c.' + QUOTENAME(@wm_col) + N' < @hi ORDER BY c.' + QUOTENAME(@wm_col) + N';';
                ELSE
                    SET @sql = N'INSERT INTO ' + @tgt2 + N' (batch_id, load_type, change_operation, is_full_snapshot, cdc_start_lsn, cdc_seqval, source_file_id, ' + @cols + N') '
                             + N'SELECT @batch_id, @load_type, ' + @op_expr + N', 0, NULL, NULL, @file_id, ' + @c_cols + N' '
                             + N'FROM ' + @src2 + N' AS c '
                             + N'WHERE c.' + QUOTENAME(@wm_col) + N' >= @lo AND c.' + QUOTENAME(@wm_col) + N' < @hi '
                             + N'ORDER BY c.' + QUOTENAME(@wm_col) + N';';

                BEGIN TRANSACTION;
                    SET @sql += N' SET @n = @@ROWCOUNT;';   -- count inside the dynamic batch
                    EXEC sys.sp_executesql @sql, N'@batch_id INT, @load_type NVARCHAR(20), @file_id INT, @lo DATETIME2(7), @hi DATETIME2(7), @n BIGINT OUTPUT',
                         @batch_id = @batch_id, @load_type = @load_type, @file_id = @source_file_id,
                         @lo = @lo_dt, @hi = @hi_dt, @n = @rows_inserted OUTPUT;

                    EXEC etl.usp_check_fault_injection @point = @fault_point;

                    EXEC etl.usp_set_watermark @watermark_name = @wm_name, @watermark_type = N'DATETIME',
                         @value_datetime = @hi_dt, @batch_id = @batch_id;
                COMMIT TRANSACTION;

                SET @message = CASE WHEN @first_run = 1 THEN N'Initial snapshot' ELSE N'Incremental' END
                             + N' up to ' + CONVERT(NVARCHAR(30), @hi_dt, 126) + N' (exclusive).';
            END;
        END

        -- =====================================================================
        -- FULL (snapshot only when the content changed)
        -- =====================================================================
        ELSE IF @load_type = N'FULL'
        BEGIN
            DECLARE @new_hash VARBINARY(32), @old_hash VARBINARY(32);
            DECLARE @wm_exists BIT = CASE WHEN EXISTS (SELECT 1 FROM audit.etl_watermark WHERE watermark_name = @wm_name) THEN 1 ELSE 0 END;

            SET @sql = N'SELECT @h = HASHBYTES(''SHA2_256'', (SELECT ' + @cols + N' FROM ' + @src2
                     + N' ORDER BY ' + @pk_cols + N' FOR JSON PATH, INCLUDE_NULL_VALUES));';
            EXEC sys.sp_executesql @sql, N'@h VARBINARY(32) OUTPUT', @h = @new_hash OUTPUT;

            EXEC etl.usp_get_watermark @watermark_name = @wm_name, @value_binary = @old_hash OUTPUT;

            IF @force_resync = 0 AND @wm_exists = 1
               AND ((@new_hash IS NULL AND @old_hash IS NULL) OR @new_hash = @old_hash)
            BEGIN
                SET @message = N'Source content unchanged (same fingerprint) - snapshot skipped.';
            END
            ELSE
            BEGIN
                SET @sql = @snapshot_sql + N'ORDER BY ' + @pk_cols + N';';

                BEGIN TRANSACTION;
                    SET @sql += N' SET @n = @@ROWCOUNT;';   -- count inside the dynamic batch
                    EXEC sys.sp_executesql @sql, N'@batch_id INT, @load_type NVARCHAR(20), @file_id INT, @n BIGINT OUTPUT',
                         @batch_id = @batch_id, @load_type = @load_type, @file_id = @source_file_id, @n = @rows_inserted OUTPUT;

                    EXEC etl.usp_check_fault_injection @point = @fault_point;

                    EXEC etl.usp_set_watermark @watermark_name = @wm_name, @watermark_type = N'HASH',
                         @value_binary = @new_hash, @batch_id = @batch_id;
                COMMIT TRANSACTION;

                SET @message = N'Full snapshot taken (content changed).';
            END;
        END
        ELSE
            THROW 50406, 'Unknown load_type in audit.etl_config.', 1;

        SET @rows_read = @rows_inserted;
        PRINT '>> ' + @tgt_name + ': ' + CAST(@rows_inserted AS NVARCHAR(20)) + ' row(s). ' + ISNULL(@message, N'');
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;

        IF @load_type = N'CDC'
            UPDATE audit.cdc_control
            SET status = N'FAILED', last_error = LEFT(ERROR_MESSAGE(), 4000)
            WHERE config_id = @config_id;

        THROW;
    END CATCH;
END;
GO
