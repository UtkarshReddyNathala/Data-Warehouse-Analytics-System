/*
===============================================================================
Stored Procedure: etl.usp_ingest_source_file  (CSV file -> landing -> source)
===============================================================================
In short:
    Loads one CSV file into its source table. Files that have not changed are
    skipped, bad rows are set aside with a reason instead of being lost, and
    only rows that really changed are written.

Script Purpose:
    Loads one configured CSV file into its simulated operational source table.
    Everything is driven by audit.etl_config - there is no table-specific code.

    1. File-level change detection
         - SHA2_256 checksum of the whole file (OPENROWSET ... SINGLE_BLOB)
         - NEW / MODIFIED / REPROCESS (last attempt with this content failed)
         - UNCHANGED files are skipped (duplicate file prevention)
         - every attempt is recorded in audit.file_ingestion_log
    2. BULK INSERT the raw text into the landing table
    3. Convert every value to the source column's data type (TRY_CONVERT),
       using the column types read from sys.columns
    4. Reject (never silently drop) rows with:
         - a missing business key (MISSING_KEY) or an unreadable one (INVALID_KEY)
         - values that cannot be converted to the column type
         - a duplicate business key (the winner is chosen with dedup_order_by)
       Rejected rows go to silver.rejected_records with stage = 'INGESTION'.
    5. MERGE the valid rows into the source table. Only rows whose values really
       changed are updated, so SQL Server CDC captures genuine changes only.
       A row counts as MISSING only when its business key does not appear in the
       file at all. A row that is present but invalid keeps its current values
       (it is never deleted because of a bad value in another column).
       Missing rows are deleted (CDC tables) or soft deleted (ERP tables),
       depending on missing_row_action.
       If any record in the file has a blank or unreadable key, it could be any
       existing record whose key was lost, so deletions are suspended for that
       load. Completely empty lines are ignored for this rule.
    6. Safety limit: a file that would delete more than ingestion_max_delete_pct
       percent of the table is rejected (protects against truncated files).

    Steps 4-5 run in one transaction.

Parameters:
    @batch_id       Pipeline batch id.
    @config_id      Row in audit.etl_config.
    @force_reload   1 = process the file even when its checksum is unchanged.
    OUTPUT          Row counts and @status (SUCCESS / SKIPPED_DUPLICATE).
===============================================================================
*/

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

USE DataWarehouse;
GO

CREATE OR ALTER PROCEDURE etl.usp_ingest_source_file
    @batch_id       INT,
    @config_id      INT,
    @force_reload   BIT = 0,
    @rows_read      BIGINT = 0 OUTPUT,
    @rows_inserted  BIGINT = 0 OUTPUT,
    @rows_updated   BIGINT = 0 OUTPUT,
    @rows_deleted   BIGINT = 0 OUTPUT,
    @rows_rejected  BIGINT = 0 OUTPUT,
    @status         NVARCHAR(20) = NULL OUTPUT,
    @message        NVARCHAR(1000) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SELECT @rows_read = 0, @rows_inserted = 0, @rows_updated = 0, @rows_deleted = 0, @rows_rejected = 0, @status = NULL, @message = NULL;
    DECLARE @unreadable_keys BIGINT = 0;

    -- -------------------------------------------------------------------------
    -- Configuration
    -- -------------------------------------------------------------------------
    DECLARE @src_schema SYSNAME, @src_table SYSNAME, @landing SYSNAME, @rel_path NVARCHAR(400),
            @fmt CHAR(3), @pk_list NVARCHAR(400), @dedup NVARCHAR(400), @missing NVARCHAR(20);

    SELECT @src_schema = source_schema,
           @src_table  = source_table,
           @landing    = landing_table,
           @rel_path   = source_file_path,
           @fmt        = file_date_format,
           @pk_list    = primary_key_columns,
           @dedup      = dedup_order_by,
           @missing    = missing_row_action
    FROM audit.etl_config
    WHERE config_id = @config_id;

    IF @src_table IS NULL
        THROW 50200, 'etl.usp_ingest_source_file: configuration row not found.', 1;
    IF @rel_path IS NULL OR @landing IS NULL
        THROW 50200, 'etl.usp_ingest_source_file: no source file / landing table configured for this table.', 1;

    DECLARE @data_root  NVARCHAR(4000) = audit.fn_get_setting(N'data_root');
    DECLARE @codepage   NVARCHAR(20)   = ISNULL(audit.fn_get_setting(N'bulk_insert_codepage'), N'65001');
    DECLARE @max_pct    DECIMAL(9, 4)  = ISNULL(TRY_CAST(audit.fn_get_setting(N'ingestion_max_delete_pct') AS DECIMAL(9, 4)), 50);
    DECLARE @separator  NCHAR(1)       = CASE WHEN CHARINDEX(N'/', @data_root) > 0 THEN N'/' ELSE N'\' END;
    DECLARE @full_path  NVARCHAR(1000) = @data_root + REPLACE(REPLACE(@rel_path, N'\', @separator), N'/', @separator);
    DECLARE @file_name  NVARCHAR(260)  = RIGHT(@full_path, CHARINDEX(@separator, REVERSE(@separator + @full_path)) - 1);
    DECLARE @path_lit   NVARCHAR(2100) = N'N''' + REPLACE(@full_path, N'''', N'''''') + N'''';

    DECLARE @src2  NVARCHAR(300) = QUOTENAME(@src_schema) + N'.' + QUOTENAME(@src_table);
    DECLARE @land2 NVARCHAR(300) = N'[landing].' + QUOTENAME(@landing);
    DECLARE @view2 NVARCHAR(300) = N'[landing].' + QUOTENAME(N'vw_' + @landing + N'_bulk');
    DECLARE @src_name NVARCHAR(300) = @src_schema + N'.' + @src_table;
    DECLARE @is_soft BIT = CASE WHEN @missing = N'SOFT_DELETE' THEN 1 ELSE 0 END;

    IF @data_root IS NULL
        THROW 50200, 'Setting data_root is empty. Run EXEC etl.usp_set_setting N''data_root'', N''<folder>''.', 1;

    DECLARE @file_id INT, @file_hash VARBINARY(32), @file_size BIGINT, @change_type NVARCHAR(20);
    DECLARE @last_success_hash VARBINARY(32), @last_attempt_hash VARBINARY(32), @last_attempt_status NVARCHAR(20);
    DECLARE @sql NVARCHAR(MAX);

    INSERT INTO audit.file_ingestion_log (config_id, file_name, file_path, batch_id, status)
    VALUES (@config_id, @file_name, @full_path, @batch_id, N'PROCESSING');
    SET @file_id = SCOPE_IDENTITY();

    BEGIN TRY
        -- ---------------------------------------------------------------------
        -- 1. Checksum and file-level change detection
        -- ---------------------------------------------------------------------
        SET @sql = N'SELECT @h = HASHBYTES(''SHA2_256'', f.BulkColumn), @s = DATALENGTH(f.BulkColumn) '
                 + N'FROM OPENROWSET(BULK ' + @path_lit + N', SINGLE_BLOB) AS f;';
        EXEC sys.sp_executesql @sql, N'@h VARBINARY(32) OUTPUT, @s BIGINT OUTPUT',
             @h = @file_hash OUTPUT, @s = @file_size OUTPUT;

        SELECT TOP (1) @last_success_hash = file_hash
        FROM audit.file_ingestion_log
        WHERE config_id = @config_id AND status = N'SUCCESS'
        ORDER BY file_id DESC;

        SELECT TOP (1) @last_attempt_hash = file_hash, @last_attempt_status = status
        FROM audit.file_ingestion_log
        WHERE config_id = @config_id AND file_id < @file_id AND status IN (N'SUCCESS', N'FAILED')
        ORDER BY file_id DESC;

        SET @change_type = CASE
            WHEN @force_reload = 1                                                     THEN N'FORCED'
            WHEN @last_success_hash = @file_hash                                       THEN N'UNCHANGED'
            WHEN @last_attempt_status = N'FAILED' AND @last_attempt_hash = @file_hash THEN N'REPROCESS'
            WHEN @last_success_hash IS NULL                                            THEN N'NEW'
            ELSE N'MODIFIED' END;

        IF @change_type = N'UNCHANGED'
        BEGIN
            UPDATE audit.file_ingestion_log
            SET file_hash = @file_hash, file_size = @file_size, change_type = @change_type,
                status = N'SKIPPED_DUPLICATE', processed_at = SYSDATETIME()
            WHERE file_id = @file_id;

            SET @status = N'SKIPPED_DUPLICATE';
            PRINT '>> ' + @file_name + ' unchanged since the last successful load - skipped.';
            RETURN;
        END;

        UPDATE audit.file_ingestion_log
        SET file_hash = @file_hash, file_size = @file_size, change_type = @change_type
        WHERE file_id = @file_id;

        -- ---------------------------------------------------------------------
        -- 2. Raw file -> landing table
        -- ---------------------------------------------------------------------
        SET @sql = N'TRUNCATE TABLE ' + @land2 + N';';
        EXEC sys.sp_executesql @sql;

        SET @sql = N'BULK INSERT ' + @view2 + N' FROM ' + @path_lit + N' WITH ('
                 + N'FORMAT = ''CSV'', FIRSTROW = 2, FIELDTERMINATOR = '','', ROWTERMINATOR = ''0x0a'', '
                 + N'CODEPAGE = ''' + REPLACE(@codepage, N'''', N'') + N''', KEEPNULLS);';
        EXEC sys.sp_executesql @sql;

        SET @sql = N'SELECT @n = COUNT_BIG(*) FROM ' + @land2 + N';';
        EXEC sys.sp_executesql @sql, N'@n BIGINT OUTPUT', @n = @rows_read OUTPUT;

        -- ---------------------------------------------------------------------
        -- 3. Build the column-level SQL fragments from the catalog
        -- ---------------------------------------------------------------------
        DECLARE @cols TABLE (column_id INT, name SYSNAME, type_sql NVARCHAR(100), is_pk BIT);

        INSERT INTO @cols (column_id, name, type_sql, is_pk)
        SELECT
            c.column_id,
            c.name,
            CASE
                WHEN t.name IN (N'nvarchar', N'nchar')
                    THEN t.name + N'(' + CASE WHEN c.max_length = -1 THEN N'MAX' ELSE CAST(c.max_length / 2 AS NVARCHAR(10)) END + N')'
                WHEN t.name IN (N'varchar', N'char', N'varbinary', N'binary')
                    THEN t.name + N'(' + CASE WHEN c.max_length = -1 THEN N'MAX' ELSE CAST(c.max_length AS NVARCHAR(10)) END + N')'
                WHEN t.name IN (N'decimal', N'numeric')
                    THEN t.name + N'(' + CAST(c.[precision] AS NVARCHAR(10)) + N',' + CAST(c.scale AS NVARCHAR(10)) + N')'
                WHEN t.name IN (N'datetime2', N'time', N'datetimeoffset')
                    THEN t.name + N'(' + CAST(c.scale AS NVARCHAR(10)) + N')'
                ELSE t.name
            END,
            CASE WHEN EXISTS (SELECT 1 FROM STRING_SPLIT(@pk_list, N',') AS k WHERE TRIM(k.value) = c.name) THEN 1 ELSE 0 END
        FROM sys.columns AS c
        JOIN sys.types   AS t ON t.user_type_id = c.user_type_id
        WHERE c.object_id = OBJECT_ID(@src2)
          AND c.name <> N'landing_row_id'
          AND COL_LENGTH(@land2, c.name) IS NOT NULL;

        IF NOT EXISTS (SELECT 1 FROM @cols WHERE is_pk = 1)
            THROW 50202, 'No primary key column of the configuration was found in the landing/source tables.', 1;

        DECLARE @typed_select NVARCHAR(MAX), @conv_check NVARCHAR(MAX), @json_cols NVARCHAR(MAX),
                @pk_null NVARCHAR(MAX), @pk_cols NVARCHAR(MAX), @join NVARCHAR(MAX),
                @all_cols NVARCHAR(MAX), @s_cols NVARCHAR(MAX), @diff_s NVARCHAR(MAX), @diff_t NVARCHAR(MAX),
                @update_set NVARCHAR(MAX), @dedup_sql NVARCHAR(MAX) = N'',
                @key_unreadable NVARCHAR(MAX), @join_o NVARCHAR(MAX), @row_empty NVARCHAR(MAX);

        SELECT
            @typed_select = STRING_AGG(CAST(N'TRY_CONVERT(' + type_sql + N', NULLIF(REPLACE(l.' + QUOTENAME(name) + N', NCHAR(13), N''''), N'''')) AS ' + QUOTENAME(name) AS NVARCHAR(MAX)), N', ')
                            WITHIN GROUP (ORDER BY column_id),
            @conv_check   = N'N''''' + STRING_AGG(CAST(N' + CASE WHEN NULLIF(REPLACE(l.' + QUOTENAME(name) + N', NCHAR(13), N''''), N'''') IS NOT NULL AND TRY_CONVERT('
                            + type_sql + N', NULLIF(REPLACE(l.' + QUOTENAME(name) + N', NCHAR(13), N''''), N'''')) IS NULL THEN N''' + name + N' '' ELSE N'''' END' AS NVARCHAR(MAX)), N'')
                            WITHIN GROUP (ORDER BY column_id),
            @json_cols    = STRING_AGG(CAST(N'l.' + QUOTENAME(name) + N' AS ' + QUOTENAME(name) AS NVARCHAR(MAX)), N', ')
                            WITHIN GROUP (ORDER BY column_id),
            @all_cols     = STRING_AGG(CAST(QUOTENAME(name) AS NVARCHAR(MAX)), N', ')
                            WITHIN GROUP (ORDER BY column_id),
            @s_cols       = STRING_AGG(CAST(N's.' + QUOTENAME(name) AS NVARCHAR(MAX)), N', ')
                            WITHIN GROUP (ORDER BY column_id),
            -- every value in the row is empty: a blank line, not a record
            @row_empty    = STRING_AGG(CAST(N'NULLIF(TRIM(REPLACE(l.' + QUOTENAME(name) + N', NCHAR(13), N'''')), N'''') IS NULL' AS NVARCHAR(MAX)), N' AND ')
                            WITHIN GROUP (ORDER BY column_id)
        FROM @cols;

        SELECT
            @pk_null = STRING_AGG(CAST(QUOTENAME(name) + N' IS NULL' AS NVARCHAR(MAX)), N' OR ') WITHIN GROUP (ORDER BY column_id),
            @pk_cols = STRING_AGG(CAST(QUOTENAME(name) AS NVARCHAR(MAX)), N', ') WITHIN GROUP (ORDER BY column_id),
            @join    = STRING_AGG(CAST(N't.' + QUOTENAME(name) + N' = s.' + QUOTENAME(name) AS NVARCHAR(MAX)), N' AND ') WITHIN GROUP (ORDER BY column_id),
            @join_o  = STRING_AGG(CAST(N't.' + QUOTENAME(name) + N' = o.' + QUOTENAME(name) AS NVARCHAR(MAX)), N' AND ') WITHIN GROUP (ORDER BY column_id),
            -- a key value is present in the file but cannot be converted to the key type
            @key_unreadable = STRING_AGG(CAST(N'(NULLIF(REPLACE(l.' + QUOTENAME(name) + N', NCHAR(13), N''''), N'''') IS NOT NULL AND TRY_CONVERT('
                              + type_sql + N', NULLIF(REPLACE(l.' + QUOTENAME(name) + N', NCHAR(13), N''''), N'''')) IS NULL)' AS NVARCHAR(MAX)), N' OR ')
                              WITHIN GROUP (ORDER BY column_id)
        FROM @cols WHERE is_pk = 1;

        SELECT
            @diff_s     = STRING_AGG(CAST(N's.' + QUOTENAME(name) AS NVARCHAR(MAX)), N', ') WITHIN GROUP (ORDER BY column_id),
            @diff_t     = STRING_AGG(CAST(N't.' + QUOTENAME(name) AS NVARCHAR(MAX)), N', ') WITHIN GROUP (ORDER BY column_id),
            @update_set = STRING_AGG(CAST(N't.' + QUOTENAME(name) + N' = s.' + QUOTENAME(name) AS NVARCHAR(MAX)), N', ') WITHIN GROUP (ORDER BY column_id)
        FROM @cols WHERE is_pk = 0;

        -- dedup_order_by was validated by etl.usp_validate_config (column names only)
        IF @dedup IS NOT NULL
            SELECT @dedup_sql = STRING_AGG(CAST(
                       QUOTENAME(TRIM(CASE WHEN TRIM(d.value) LIKE N'% DESC' THEN LEFT(TRIM(d.value), LEN(TRIM(d.value)) - 5)
                                           WHEN TRIM(d.value) LIKE N'% ASC'  THEN LEFT(TRIM(d.value), LEN(TRIM(d.value)) - 4)
                                           ELSE TRIM(d.value) END))
                       + CASE WHEN TRIM(d.value) LIKE N'% DESC' THEN N' DESC' ELSE N' ASC' END AS NVARCHAR(MAX)), N', ') + N', '
            FROM STRING_SPLIT(@dedup, N',') AS d;

        -- ---------------------------------------------------------------------
        -- 4 + 5. Typed staging, rejects, safety check and MERGE (one batch)
        -- ---------------------------------------------------------------------
        SET @sql = CAST(N'' AS NVARCHAR(MAX)) + N'
SET DATEFORMAT ' + @fmt + N';

SELECT l.landing_row_id, ' + @typed_select + N',
       conversion_errors = ' + @conv_check + N',
       key_unreadable    = CASE WHEN ' + @key_unreadable + N' THEN 1 ELSE 0 END,
       row_empty         = CASE WHEN ' + @row_empty + N' THEN 1 ELSE 0 END,
       record_data = (SELECT ' + @json_cols + N' FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES)
INTO #typed
FROM ' + @land2 + N' AS l;

-- Every business key that appears in the file, even when other values in the
-- row are invalid. A key in this list is never treated as "missing".
SELECT DISTINCT ' + @pk_cols + N'
INTO #observed_keys
FROM #typed
WHERE NOT (' + @pk_null + N');

-- A record whose key is unreadable (e.g. X7 for an integer key) or blank could
-- be ANY existing row whose key was lost or corrupted, so deletions of missing
-- rows are suspended for this load. Completely empty lines are not records.
SELECT @unreadable = COUNT_BIG(*) FROM #typed
WHERE key_unreadable = 1 OR ((' + @pk_null + N') AND row_empty = 0);

-- Rows with a missing/unreadable key or values that cannot be converted
INSERT INTO silver.rejected_records (batch_id, rejection_stage, source_table, source_record_id, file_id, record_data, rejection_reason)
SELECT @batch_id, N''INGESTION'', @src_name, CAST(landing_row_id AS NVARCHAR(50)), @file_id, record_data,
       CASE WHEN key_unreadable = 1 THEN N''INVALID_KEY: '' + conversion_errors
            WHEN ' + @pk_null + N' THEN N''MISSING_KEY''
            ELSE N''TYPE_CONVERSION_FAILED: '' + conversion_errors END
FROM #typed
WHERE conversion_errors <> N'''' OR ' + @pk_null + N';
SET @rej = @@ROWCOUNT;

-- Deduplicate valid rows on the business key
SELECT *, rn = ROW_NUMBER() OVER (PARTITION BY ' + @pk_cols + N' ORDER BY ' + @dedup_sql + N'landing_row_id DESC)
INTO #ranked
FROM #typed
WHERE conversion_errors = N'''' AND NOT (' + @pk_null + N');

INSERT INTO silver.rejected_records (batch_id, rejection_stage, source_table, source_record_id, file_id, record_data, rejection_reason)
SELECT @batch_id, N''INGESTION'', @src_name, CAST(landing_row_id AS NVARCHAR(50)), @file_id, record_data, N''DUPLICATE_KEY_SUPERSEDED''
FROM #ranked
WHERE rn > 1;
SET @rej += @@ROWCOUNT;

-- Safety limit: rows whose key does not appear in the file at all
DECLARE @target_rows BIGINT, @would_remove BIGINT, @m NVARCHAR(1000);
SELECT @target_rows = COUNT_BIG(*) FROM ' + @src2 + N' AS t' + CASE WHEN @is_soft = 1 THEN N' WHERE t.is_deleted = 0' ELSE N'' END + N';
SELECT @would_remove = COUNT_BIG(*) FROM ' + @src2 + N' AS t
WHERE ' + CASE WHEN @is_soft = 1 THEN N't.is_deleted = 0 AND ' ELSE N'' END + N'NOT EXISTS (SELECT 1 FROM #observed_keys AS o WHERE ' + @join_o + N');

IF @missing <> N''IGNORE'' AND @unreadable = 0 AND @target_rows > 0 AND @would_remove * 100.0 / @target_rows > @max_pct
BEGIN
    SET @m = CONCAT(N''File would remove '', @would_remove, N'' of '', @target_rows, N'' rows from ' + @src_name + N' (limit '', @max_pct, N''%). Load rejected.'');
    THROW 50201, @m, 1;
END;

-- Insert new rows and update changed rows (valid rows only). Rows that are
-- present but invalid keep their current values in the source table.
CREATE TABLE #merge_actions (action_name NVARCHAR(10));

MERGE ' + @src2 + N' WITH (HOLDLOCK) AS t
USING (SELECT ' + @all_cols + N' FROM #ranked WHERE rn = 1) AS s
    ON ' + @join + N'
WHEN MATCHED AND (EXISTS (SELECT ' + @diff_s + N' EXCEPT SELECT ' + @diff_t + N')'
       + CASE WHEN @is_soft = 1 THEN N' OR t.is_deleted = 1' ELSE N'' END + N') THEN
    UPDATE SET ' + @update_set
       + CASE WHEN @is_soft = 1 THEN N', t.is_deleted = 0, t.modified_at = SYSDATETIME()' ELSE N'' END + N'
WHEN NOT MATCHED BY TARGET THEN
    INSERT (' + @all_cols + N') VALUES (' + @s_cols + N')
OUTPUT $action INTO #merge_actions (action_name);

SELECT @ins = ISNULL(SUM(CASE WHEN action_name = N''INSERT'' THEN 1 ELSE 0 END), 0),
       @upd = ISNULL(SUM(CASE WHEN action_name = N''UPDATE'' THEN 1 ELSE 0 END), 0)
FROM #merge_actions;

-- Remove rows whose key is not in the file (only when every key was readable)
SET @del = 0;
IF @missing <> N''IGNORE'' AND @unreadable = 0
BEGIN
'      + CASE WHEN @is_soft = 1 THEN N'    UPDATE t SET t.is_deleted = 1, t.modified_at = SYSDATETIME()
    FROM ' + @src2 + N' AS t
    WHERE t.is_deleted = 0'
              ELSE N'    DELETE t
    FROM ' + @src2 + N' AS t
    WHERE 1 = 1' END + N'
      AND NOT EXISTS (SELECT 1 FROM #observed_keys AS o WHERE ' + @join_o + N');
    SET @del = @@ROWCOUNT;
END;';

        BEGIN TRANSACTION;

            EXEC sys.sp_executesql @sql,
                N'@batch_id INT, @file_id INT, @src_name NVARCHAR(300), @missing NVARCHAR(20), @max_pct DECIMAL(9,4),
                  @rej BIGINT OUTPUT, @ins BIGINT OUTPUT, @upd BIGINT OUTPUT, @del BIGINT OUTPUT, @unreadable BIGINT OUTPUT',
                @batch_id = @batch_id, @file_id = @file_id, @src_name = @src_name, @missing = @missing, @max_pct = @max_pct,
                @rej = @rows_rejected OUTPUT, @ins = @rows_inserted OUTPUT, @upd = @rows_updated OUTPUT,
                @del = @rows_deleted OUTPUT, @unreadable = @unreadable_keys OUTPUT;

            IF @unreadable_keys > 0 AND @missing <> N'IGNORE'
                SET @message = CONCAT(@unreadable_keys, N' row(s) had a blank or unreadable key. Deletion of missing rows was suspended for this load.');

            DECLARE @fault_point NVARCHAR(300) = N'INGESTION:' + @src_name;
            EXEC etl.usp_check_fault_injection @point = @fault_point;

            UPDATE audit.file_ingestion_log
            SET status        = N'SUCCESS',
                processed_at  = SYSDATETIME(),
                rows_in_file  = @rows_read,
                rows_inserted = @rows_inserted,
                rows_updated  = @rows_updated,
                rows_deleted  = @rows_deleted,
                rows_rejected = @rows_rejected,
                error_message = @message
            WHERE file_id = @file_id;

        COMMIT TRANSACTION;

        SET @status = N'SUCCESS';
        PRINT '>> ' + @file_name + ' (' + @change_type + '): read ' + CAST(@rows_read AS NVARCHAR(20))
            + ', inserted ' + CAST(@rows_inserted AS NVARCHAR(20)) + ', updated ' + CAST(@rows_updated AS NVARCHAR(20))
            + ', deleted ' + CAST(@rows_deleted AS NVARCHAR(20)) + ', rejected ' + CAST(@rows_rejected AS NVARCHAR(20));
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;

        UPDATE audit.file_ingestion_log
        SET status        = N'FAILED',
            processed_at  = SYSDATETIME(),
            rows_in_file  = @rows_read,
            error_message = LEFT(ERROR_MESSAGE(), 4000)
        WHERE file_id = @file_id;

        THROW;
    END CATCH;
END;
GO
