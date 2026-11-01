/*
===============================================================================
Stored Procedure: etl.usp_validate_config
===============================================================================
In short:
    Checks the settings in audit.etl_config before anything is loaded. A wrong
    table name, column or load type is reported straight away, instead of
    failing halfway through a load.

Script Purpose:
    Validates the metadata in audit.etl_config before anything is loaded, so
    that a wrong configuration is rejected up front instead of failing halfway
    through a load.

    Checks per configuration row:
      - source, landing, bronze and silver tables exist
      - the Silver procedure exists
      - every primary key column exists in the source and Bronze tables
      - INCREMENTAL: the watermark column exists and is ROWVERSION or a date/time
      - CDC: CDC is enabled and the capture instance belongs to the source table
      - SOFT_DELETE: the source table has is_deleted and modified_at columns
      - dedup_order_by only names real columns, optionally followed by ASC/DESC
      - every CSV (landing) column exists in the source table
      - CDC: an audit.cdc_control row exists with the same capture instance,
        and every source column is captured by that instance
      - every source column exists in Bronze with a compatible type/length
      - the configured primary key is unique and NOT NULL in the source data
      - the Silver procedure has the standard parameter contract

Parameters:
    @config_id       Validate one row (active or not). NULL = all active rows.
    @raise_error     1 = THROW if any problem is found.
    @return_results  1 = return the list of problems as a result set.
    @error_count     OUTPUT number of problems found.

Usage:
    EXEC etl.usp_validate_config @raise_error = 0, @return_results = 1;
===============================================================================
*/

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

USE DataWarehouse;
GO

CREATE OR ALTER PROCEDURE etl.usp_validate_config
    @config_id      INT = NULL,
    @raise_error    BIT = 1,
    @return_results BIT = 0,
    @error_count    INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    CREATE TABLE #cfg (
        config_id           INT,
        source_table_2part  NVARCHAR(300),
        target_table_2part  NVARCHAR(300),
        silver_table_2part  NVARCHAR(300),
        silver_proc_2part   NVARCHAR(300),
        landing_table_2part NVARCHAR(300),
        landing_view_2part  NVARCHAR(300),
        load_type           NVARCHAR(20),
        watermark_column    NVARCHAR(128),
        primary_key_columns NVARCHAR(400),
        capture_instance    NVARCHAR(128),
        source_file_path    NVARCHAR(400),
        dedup_order_by      NVARCHAR(400),
        missing_row_action  NVARCHAR(20)
    );

    CREATE TABLE #errors (
        config_id     INT,
        object_name   NVARCHAR(300),
        error_message NVARCHAR(1000)
    );

    INSERT INTO #cfg
    SELECT
        c.config_id,
        QUOTENAME(c.source_schema) + N'.' + QUOTENAME(c.source_table),
        QUOTENAME(c.target_schema) + N'.' + QUOTENAME(c.target_table),
        QUOTENAME(c.silver_schema) + N'.' + QUOTENAME(c.silver_table),
        QUOTENAME(c.silver_schema) + N'.' + QUOTENAME(c.silver_procedure),
        CASE WHEN c.landing_table IS NOT NULL THEN N'[landing].' + QUOTENAME(c.landing_table) END,
        CASE WHEN c.landing_table IS NOT NULL THEN N'[landing].' + QUOTENAME(N'vw_' + c.landing_table + N'_bulk') END,
        c.load_type, c.watermark_column, c.primary_key_columns, c.capture_instance,
        c.source_file_path, c.dedup_order_by, c.missing_row_action
    FROM audit.etl_config AS c
    WHERE (@config_id IS NULL AND c.is_active = 1)
       OR c.config_id = @config_id;

    IF @config_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM #cfg)
        INSERT INTO #errors VALUES (@config_id, NULL, N'Configuration row does not exist.');

    IF @config_id IS NULL AND NOT EXISTS (SELECT 1 FROM #cfg)
        INSERT INTO #errors VALUES (NULL, N'audit.etl_config', N'No active configuration rows found.');

    -- ---------------------------------------------------------------------
    -- Object existence
    -- ---------------------------------------------------------------------
    INSERT INTO #errors
    SELECT config_id, source_table_2part, N'Source table does not exist.'
    FROM #cfg WHERE OBJECT_ID(source_table_2part, N'U') IS NULL;

    INSERT INTO #errors
    SELECT config_id, target_table_2part, N'Bronze target table does not exist.'
    FROM #cfg WHERE OBJECT_ID(target_table_2part, N'U') IS NULL;

    INSERT INTO #errors
    SELECT config_id, silver_table_2part, N'Silver table does not exist.'
    FROM #cfg WHERE OBJECT_ID(silver_table_2part, N'U') IS NULL;

    INSERT INTO #errors
    SELECT config_id, silver_proc_2part, N'Silver procedure does not exist.'
    FROM #cfg WHERE OBJECT_ID(silver_proc_2part, N'P') IS NULL;

    INSERT INTO #errors
    SELECT config_id, ISNULL(landing_table_2part, N'(null)'), N'A source file is configured but its landing table or bulk view does not exist.'
    FROM #cfg
    WHERE source_file_path IS NOT NULL
      AND (landing_table_2part IS NULL
           OR OBJECT_ID(landing_table_2part, N'U') IS NULL
           OR OBJECT_ID(landing_view_2part, N'V') IS NULL);

    -- ---------------------------------------------------------------------
    -- Primary key columns exist in source and Bronze
    -- ---------------------------------------------------------------------
    INSERT INTO #errors
    SELECT c.config_id, c.source_table_2part,
           N'Primary key column [' + TRIM(k.value) + N'] does not exist in the source or Bronze table.'
    FROM #cfg AS c
    CROSS APPLY STRING_SPLIT(c.primary_key_columns, N',') AS k
    WHERE OBJECT_ID(c.source_table_2part, N'U') IS NOT NULL
      AND (COL_LENGTH(c.source_table_2part, TRIM(k.value)) IS NULL
           OR COL_LENGTH(c.target_table_2part, TRIM(k.value)) IS NULL);

    -- ---------------------------------------------------------------------
    -- INCREMENTAL: watermark column
    -- ---------------------------------------------------------------------
    INSERT INTO #errors
    SELECT c.config_id, c.source_table_2part,
           N'INCREMENTAL load needs a ROWVERSION or date/time watermark column. Found: ' + ISNULL(c.watermark_column, N'(none)')
    FROM #cfg AS c
    WHERE c.load_type = N'INCREMENTAL'
      AND OBJECT_ID(c.source_table_2part, N'U') IS NOT NULL
      AND NOT EXISTS (
            SELECT 1
            FROM sys.columns AS col
            WHERE col.object_id = OBJECT_ID(c.source_table_2part)
              AND col.name = c.watermark_column
              AND TYPE_NAME(col.system_type_id) IN (N'timestamp', N'datetime', N'datetime2', N'smalldatetime', N'date')
      );

    -- ---------------------------------------------------------------------
    -- CDC: database enabled and capture instance matches the source table
    -- ---------------------------------------------------------------------
    IF EXISTS (SELECT 1 FROM #cfg WHERE load_type = N'CDC')
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM sys.databases WHERE database_id = DB_ID() AND is_cdc_enabled = 1)
        BEGIN
            INSERT INTO #errors
            SELECT config_id, source_table_2part, N'CDC is not enabled on this database. Run EXEC etl.usp_enable_cdc.'
            FROM #cfg WHERE load_type = N'CDC';
        END
        ELSE
        BEGIN
            -- cdc.change_tables only exists after CDC is enabled, so use dynamic SQL
            INSERT INTO #errors
            EXEC sys.sp_executesql N'
                SELECT c.config_id, c.source_table_2part,
                       N''Capture instance '' + c.capture_instance + N'' does not exist for this source table. Run EXEC etl.usp_enable_cdc.''
                FROM #cfg AS c
                WHERE c.load_type = N''CDC''
                  AND NOT EXISTS (
                        SELECT 1
                        FROM cdc.change_tables AS ct
                        WHERE ct.capture_instance = c.capture_instance
                          AND ct.source_object_id = OBJECT_ID(c.source_table_2part)
                  );';

            -- Every source column must be captured; a column added after CDC was
            -- enabled is not in the capture instance until it is re-created.
            INSERT INTO #errors
            EXEC sys.sp_executesql N'
                SELECT c.config_id, c.source_table_2part,
                       N''Source column ['' + sc.name + N''] is not captured by CDC instance '' + c.capture_instance
                       + N''. Re-create the capture instance.''
                FROM #cfg AS c
                JOIN cdc.change_tables AS ct
                    ON ct.capture_instance = c.capture_instance
                JOIN sys.columns AS sc
                    ON sc.object_id = OBJECT_ID(c.source_table_2part)
                WHERE c.load_type = N''CDC''
                  AND NOT EXISTS (SELECT 1 FROM cdc.captured_columns AS cc
                                  WHERE cc.object_id = ct.object_id AND cc.column_name = sc.name);';
        END;

        -- The LSN watermark row must exist and belong to the same capture instance
        INSERT INTO #errors
        SELECT c.config_id, c.source_table_2part,
               CASE WHEN cc.config_id IS NULL
                    THEN N'No audit.cdc_control row for this CDC table. Run EXEC etl.usp_enable_cdc.'
                    ELSE N'audit.cdc_control uses capture instance ' + cc.capture_instance
                       + N' but the configuration uses ' + c.capture_instance + N'.' END
        FROM #cfg AS c
        LEFT JOIN audit.cdc_control AS cc ON cc.config_id = c.config_id
        WHERE c.load_type = N'CDC'
          AND (cc.config_id IS NULL OR cc.capture_instance <> c.capture_instance);
    END;

    -- ---------------------------------------------------------------------
    -- SOFT_DELETE needs is_deleted + modified_at in the source table
    -- ---------------------------------------------------------------------
    INSERT INTO #errors
    SELECT config_id, source_table_2part, N'SOFT_DELETE requires is_deleted and modified_at columns in the source table.'
    FROM #cfg
    WHERE missing_row_action = N'SOFT_DELETE'
      AND OBJECT_ID(source_table_2part, N'U') IS NOT NULL
      AND (COL_LENGTH(source_table_2part, N'is_deleted') IS NULL OR COL_LENGTH(source_table_2part, N'modified_at') IS NULL);

    -- ---------------------------------------------------------------------
    -- dedup_order_by: "column [ASC|DESC], ..." with real column names only
    -- ---------------------------------------------------------------------
    INSERT INTO #errors
    SELECT c.config_id, c.source_table_2part,
           N'Invalid dedup_order_by item: ' + TRIM(d.value)
    FROM #cfg AS c
    CROSS APPLY STRING_SPLIT(c.dedup_order_by, N',') AS d
    CROSS APPLY (
        SELECT col_name = TRIM(CASE
                    WHEN TRIM(d.value) LIKE N'% DESC' THEN LEFT(TRIM(d.value), LEN(TRIM(d.value)) - 5)
                    WHEN TRIM(d.value) LIKE N'% ASC'  THEN LEFT(TRIM(d.value), LEN(TRIM(d.value)) - 4)
                    ELSE TRIM(d.value) END)
    ) AS p
    WHERE c.dedup_order_by IS NOT NULL
      AND (p.col_name LIKE N'%[^A-Za-z0-9_]%'
           OR COL_LENGTH(c.source_table_2part, p.col_name) IS NULL
           OR (c.landing_table_2part IS NOT NULL AND COL_LENGTH(c.landing_table_2part, p.col_name) IS NULL));

    -- ---------------------------------------------------------------------
    -- Every landing (CSV) column must exist in the source table
    -- ---------------------------------------------------------------------
    INSERT INTO #errors
    SELECT c.config_id, c.landing_table_2part,
           N'Landing column [' + lc.name + N'] does not exist in the source table.'
    FROM #cfg AS c
    JOIN sys.columns AS lc
        ON lc.object_id = OBJECT_ID(c.landing_table_2part)
    WHERE c.source_file_path IS NOT NULL
      AND lc.name <> N'landing_row_id'
      AND OBJECT_ID(c.source_table_2part, N'U') IS NOT NULL
      AND COL_LENGTH(c.source_table_2part, lc.name) IS NULL;

    -- ---------------------------------------------------------------------
    -- Source -> Bronze column compatibility
    --   every source business column must exist in Bronze with the same data
    --   type and a length that is at least as large (otherwise it would be
    --   silently dropped or truncated)
    -- ---------------------------------------------------------------------
    INSERT INTO #errors
    SELECT c.config_id, c.target_table_2part,
           CASE WHEN bc.name IS NULL
                THEN N'Source column [' + sc.name + N'] does not exist in the Bronze table.'
                ELSE N'Column [' + sc.name + N'] has type ' + TYPE_NAME(sc.user_type_id) + N'(' + CAST(sc.max_length AS NVARCHAR(10))
                   + N') in the source but ' + TYPE_NAME(bc.user_type_id) + N'(' + CAST(bc.max_length AS NVARCHAR(10)) + N') in Bronze.' END
    FROM #cfg AS c
    JOIN sys.columns AS sc
        ON sc.object_id = OBJECT_ID(c.source_table_2part)
    LEFT JOIN sys.columns AS bc
        ON bc.object_id = OBJECT_ID(c.target_table_2part) AND bc.name = sc.name
    WHERE OBJECT_ID(c.target_table_2part, N'U') IS NOT NULL
      AND TYPE_NAME(sc.user_type_id) <> N'timestamp'          -- rowversion is a watermark, not data
      AND sc.is_computed = 0
      AND (bc.name IS NULL
           OR bc.user_type_id <> sc.user_type_id
           OR (bc.max_length <> -1 AND (sc.max_length = -1 OR bc.max_length < sc.max_length)));

    -- ---------------------------------------------------------------------
    -- Silver procedure parameter contract
    --   @batch_id INT, and OUTPUT parameters @rows_read, @rows_inserted,
    --   @rows_updated, @rows_deleted, @rows_rejected, @message
    -- ---------------------------------------------------------------------
    INSERT INTO #errors
    SELECT c.config_id, c.silver_proc_2part,
           N'Silver procedure is missing parameter ' + req.name
           + CASE WHEN req.is_output = 1 THEN N' (OUTPUT)' ELSE N'' END + N'.'
    FROM #cfg AS c
    CROSS JOIN (VALUES (N'@batch_id', 0), (N'@rows_read', 1), (N'@rows_inserted', 1), (N'@rows_updated', 1),
                       (N'@rows_deleted', 1), (N'@rows_rejected', 1), (N'@message', 1)) AS req (name, is_output)
    WHERE OBJECT_ID(c.silver_proc_2part, N'P') IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM sys.parameters AS p
                      WHERE p.object_id = OBJECT_ID(c.silver_proc_2part)
                        AND p.name = req.name
                        AND (req.is_output = 0 OR p.is_output = 1));

    -- ---------------------------------------------------------------------
    -- The configured primary key must really be unique and not NULL in the
    -- source table (checked on the data, so it also catches a wrong key list)
    -- ---------------------------------------------------------------------
    DECLARE @chk_id INT, @chk_table NVARCHAR(300), @chk_pk NVARCHAR(MAX), @chk_null NVARCHAR(MAX),
            @chk_sql NVARCHAR(MAX), @dupes BIGINT, @nulls BIGINT;
    DECLARE @pk_todo TABLE (config_id INT PRIMARY KEY, source_table_2part NVARCHAR(300), pk_list NVARCHAR(400));

    INSERT INTO @pk_todo (config_id, source_table_2part, pk_list)
    SELECT c.config_id, c.source_table_2part, c.primary_key_columns
    FROM #cfg AS c
    WHERE OBJECT_ID(c.source_table_2part, N'U') IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM #errors AS e WHERE e.config_id = c.config_id
                      AND e.error_message LIKE N'Primary key column%');

    WHILE EXISTS (SELECT 1 FROM @pk_todo)
    BEGIN
        SELECT TOP (1) @chk_id = config_id, @chk_table = source_table_2part
        FROM @pk_todo ORDER BY config_id;

        SELECT @chk_pk   = STRING_AGG(CAST(QUOTENAME(TRIM(k.value)) AS NVARCHAR(MAX)), N', '),
               @chk_null = STRING_AGG(CAST(QUOTENAME(TRIM(k.value)) + N' IS NULL' AS NVARCHAR(MAX)), N' OR ')
        FROM @pk_todo AS t
        CROSS APPLY STRING_SPLIT(t.pk_list, N',') AS k
        WHERE t.config_id = @chk_id;

        SET @chk_sql = N'SELECT @d = COUNT_BIG(*) FROM (SELECT ' + @chk_pk + N' FROM ' + @chk_table
                     + N' GROUP BY ' + @chk_pk + N' HAVING COUNT_BIG(*) > 1) AS x; '
                     + N'SELECT @n = COUNT_BIG(*) FROM ' + @chk_table + N' WHERE ' + @chk_null + N';';
        EXEC sys.sp_executesql @chk_sql, N'@d BIGINT OUTPUT, @n BIGINT OUTPUT', @d = @dupes OUTPUT, @n = @nulls OUTPUT;

        IF @dupes > 0 OR @nulls > 0
            INSERT INTO #errors
            VALUES (@chk_id, @chk_table,
                    CONCAT(N'Configured primary key is not unique in the source data: ', @dupes,
                           N' duplicate key value(s), ', @nulls, N' row(s) with a NULL key.'));

        DELETE FROM @pk_todo WHERE config_id = @chk_id;
    END;

    -- ---------------------------------------------------------------------
    -- Result
    -- ---------------------------------------------------------------------
    SELECT @error_count = COUNT(*) FROM #errors;

    IF @return_results = 1
        SELECT config_id, object_name, error_message FROM #errors ORDER BY config_id;

    IF @error_count > 0 AND @raise_error = 1
    BEGIN
        DECLARE @msg NVARCHAR(2048);
        SELECT TOP (1)
            @msg = N'Configuration validation failed (' + CAST(@error_count AS NVARCHAR(10)) + N' problem(s)). First problem: config_id '
                 + ISNULL(CAST(config_id AS NVARCHAR(10)), N'-') + N', ' + ISNULL(object_name, N'') + N': ' + error_message
        FROM #errors
        ORDER BY config_id;

        THROW 50100, @msg, 1;
    END;
END;
GO
