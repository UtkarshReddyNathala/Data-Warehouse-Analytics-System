/*
===============================================================================
Stored Procedures: Load Silver Layer (Bronze -> Silver, incremental)
===============================================================================
In short:
    One procedure per Silver table. Each one takes only the new Bronze rows,
    cleans them (trims text, fixes codes and dates), sets aside bad rows, and
    updates Silver in one safe step.

Script Purpose:
    One procedure per Silver table. They are called by the metadata-driven
    loader (etl.usp_run_metadata_driven_load) using the silver_procedure name
    stored in audit.etl_config.

    Every procedure follows the same pattern:
      1. Read only NEW Bronze rows: bronze_id between the Silver watermark and
         the current maximum (etl.usp_get_bronze_window).
      2. Deduplicate change records: keep the latest change per business key
         (ROW_NUMBER ... ORDER BY bronze_id DESC). 'B' rows (CDC before
         images) are ignored. If a full snapshot is in the window, only the
         snapshot and later changes are used.
      3. Clean and standardise (trim, codes -> readable values, invalid dates,
         wrong sales amounts, country codes, ...).
      4. Validate. Records that break a rule go to silver.rejected_records
         with the reason - they are never silently discarded.
      5. In ONE transaction:
           - MERGE inserts new keys and updates changed rows only
             (SHA2_256 row hash comparison),
           - apply deletes as soft deletes (is_deleted = 1),
           - keys missing from a full snapshot are soft deleted,
           - move the Silver watermark to the last processed bronze_id.

    Re-running after a failure is safe: the watermark only moves when the
    data is committed, and MERGE/updates are idempotent.

Common OUTPUT parameters:
    @rows_read, @rows_inserted, @rows_updated, @rows_deleted, @rows_rejected, @message
===============================================================================
*/

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

USE DataWarehouse;
GO

-- =============================================================================
-- etl.usp_get_bronze_window  (shared helper)
-- =============================================================================
CREATE OR ALTER PROCEDURE etl.usp_get_bronze_window
    @bronze_table      NVARCHAR(300),     -- e.g. N'bronze.crm_cust_info'
    @watermark_name    NVARCHAR(200),
    @from_id           BIGINT OUTPUT,     -- exclusive
    @to_id             BIGINT OUTPUT,     -- inclusive
    @snapshot_start_id BIGINT OUTPUT,     -- first row of the latest full snapshot in the window (or NULL)
    @rows_in_window    BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @tbl NVARCHAR(300) = QUOTENAME(PARSENAME(@bronze_table, 2)) + N'.' + QUOTENAME(PARSENAME(@bronze_table, 1));
    DECLARE @sql NVARCHAR(MAX);

    SELECT @from_id = NULL, @to_id = NULL, @snapshot_start_id = NULL, @rows_in_window = 0;

    EXEC etl.usp_get_watermark @watermark_name = @watermark_name, @value_bigint = @from_id OUTPUT;
    SET @from_id = ISNULL(@from_id, 0);

    SET @sql = N'SELECT @t = MAX(bronze_id) FROM ' + @tbl + N';';
    EXEC sys.sp_executesql @sql, N'@t BIGINT OUTPUT', @t = @to_id OUTPUT;

    IF @to_id IS NULL OR @to_id <= @from_id
    BEGIN
        SET @to_id = @from_id;
        RETURN;
    END;

    SET @sql = N'
        SELECT @n = COUNT_BIG(*) FROM ' + @tbl + N' WHERE bronze_id > @f AND bronze_id <= @t;

        SELECT @s = MIN(b.bronze_id)
        FROM ' + @tbl + N' AS b
        WHERE b.bronze_id > @f AND b.bronze_id <= @t AND b.is_full_snapshot = 1
          AND b.batch_id = (SELECT MAX(x.batch_id) FROM ' + @tbl + N' AS x
                            WHERE x.bronze_id > @f AND x.bronze_id <= @t AND x.is_full_snapshot = 1);';

    EXEC sys.sp_executesql @sql, N'@f BIGINT, @t BIGINT, @n BIGINT OUTPUT, @s BIGINT OUTPUT',
         @f = @from_id, @t = @to_id, @n = @rows_in_window OUTPUT, @s = @snapshot_start_id OUTPUT;
END;
GO

-- =============================================================================
-- silver.usp_load_crm_cust_info
-- =============================================================================
CREATE OR ALTER PROCEDURE silver.usp_load_crm_cust_info
    @batch_id      INT,
    @rows_read     BIGINT = 0 OUTPUT,
    @rows_inserted BIGINT = 0 OUTPUT,
    @rows_updated  BIGINT = 0 OUTPUT,
    @rows_deleted  BIGINT = 0 OUTPUT,
    @rows_rejected BIGINT = 0 OUTPUT,
    @message       NVARCHAR(1000) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SELECT @rows_read = 0, @rows_inserted = 0, @rows_updated = 0, @rows_deleted = 0, @rows_rejected = 0, @message = NULL;

    DECLARE @wm NVARCHAR(200) = N'silver:bronze.crm_cust_info', @from BIGINT, @to BIGINT, @snap BIGINT;
    DECLARE @today DATE = CAST(SYSDATETIME() AS DATE);

    EXEC etl.usp_get_bronze_window N'bronze.crm_cust_info', @wm, @from OUTPUT, @to OUTPUT, @snap OUTPUT, @rows_read OUTPUT;
    IF @to <= @from BEGIN SET @message = N'No new Bronze rows.'; RETURN; END;

    -- 1. Latest change per customer -------------------------------------------
    SELECT b.bronze_id, b.change_operation, b.cst_id, b.cst_key, b.cst_firstname, b.cst_lastname,
           b.cst_marital_status, b.cst_gndr, b.cst_create_date
    INTO #latest
    FROM (
        SELECT x.*, rn = ROW_NUMBER() OVER (PARTITION BY x.cst_id ORDER BY x.bronze_id DESC)
        FROM bronze.crm_cust_info AS x
        WHERE x.bronze_id > @from AND x.bronze_id <= @to
          AND x.change_operation <> 'B'
          AND (@snap IS NULL OR x.bronze_id >= @snap)
    ) AS b
    WHERE b.rn = 1;

    -- 2 + 3. Clean, standardise and validate ------------------------------------
    SELECT
        l.bronze_id,
        l.cst_id,
        is_delete = CASE WHEN l.change_operation = 'D' THEN 1 ELSE 0 END,
        c.cst_key, c.cst_firstname, c.cst_lastname, c.cst_marital_status, c.cst_gndr, c.cst_create_date,
        rejection_reason = CASE
            WHEN l.change_operation = 'D'                       THEN NULL
            WHEN c.cst_key IS NULL                              THEN N'MISSING_CUSTOMER_KEY'
            WHEN c.cst_create_date > @today                     THEN N'FUTURE_CREATE_DATE'
            ELSE NULL END,
        row_hash = HASHBYTES('SHA2_256', CONCAT(
            ISNULL(c.cst_key, N'~'), N'|', ISNULL(c.cst_firstname, N'~'), N'|', ISNULL(c.cst_lastname, N'~'), N'|',
            c.cst_marital_status, N'|', c.cst_gndr, N'|', ISNULL(CONVERT(NVARCHAR(10), c.cst_create_date, 23), N'~'))),
        record_data = (SELECT l.cst_id, l.cst_key, l.cst_firstname, l.cst_lastname, l.cst_marital_status, l.cst_gndr,
                              l.cst_create_date, l.change_operation FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES)
    INTO #validated
    FROM #latest AS l
    CROSS APPLY (
        SELECT
            cst_key            = NULLIF(UPPER(TRIM(l.cst_key)), N''),
            cst_firstname      = NULLIF(TRIM(l.cst_firstname), N''),
            cst_lastname       = NULLIF(TRIM(l.cst_lastname), N''),
            cst_marital_status = CASE UPPER(TRIM(l.cst_marital_status))
                                     WHEN N'S' THEN N'Single' WHEN N'SINGLE'  THEN N'Single'
                                     WHEN N'M' THEN N'Married' WHEN N'MARRIED' THEN N'Married'
                                     ELSE N'n/a' END,
            cst_gndr           = CASE WHEN UPPER(TRIM(l.cst_gndr)) IN (N'F', N'FEMALE') THEN N'Female'
                                      WHEN UPPER(TRIM(l.cst_gndr)) IN (N'M', N'MALE')   THEN N'Male'
                                      ELSE N'n/a' END,
            cst_create_date    = l.cst_create_date
    ) AS c;

    INSERT INTO silver.rejected_records (batch_id, rejection_stage, source_table, source_record_id, record_data, rejection_reason)
    SELECT @batch_id, N'SILVER', N'bronze.crm_cust_info', CAST(bronze_id AS NVARCHAR(50)), record_data, rejection_reason
    FROM #validated
    WHERE rejection_reason IS NOT NULL;
    SET @rows_rejected = @@ROWCOUNT;

    CREATE TABLE #actions (action_name NVARCHAR(10));

    -- 4. Apply ------------------------------------------------------------------
    BEGIN TRY
        BEGIN TRANSACTION;

            MERGE silver.crm_cust_info WITH (HOLDLOCK) AS t
            USING (SELECT * FROM #validated WHERE is_delete = 0 AND rejection_reason IS NULL) AS s
                ON t.cst_id = s.cst_id
            WHEN MATCHED AND (t.dwh_row_hash <> s.row_hash OR t.is_deleted = 1) THEN
                UPDATE SET t.cst_key = s.cst_key, t.cst_firstname = s.cst_firstname, t.cst_lastname = s.cst_lastname,
                           t.cst_marital_status = s.cst_marital_status, t.cst_gndr = s.cst_gndr,
                           t.cst_create_date = s.cst_create_date, t.is_deleted = 0,
                           t.dwh_batch_id = @batch_id, t.dwh_source_bronze_id = s.bronze_id,
                           t.dwh_update_date = SYSDATETIME(), t.dwh_row_hash = s.row_hash
            WHEN NOT MATCHED BY TARGET THEN
                INSERT (cst_id, cst_key, cst_firstname, cst_lastname, cst_marital_status, cst_gndr, cst_create_date,
                        is_deleted, dwh_batch_id, dwh_source_bronze_id, dwh_row_hash)
                VALUES (s.cst_id, s.cst_key, s.cst_firstname, s.cst_lastname, s.cst_marital_status, s.cst_gndr, s.cst_create_date,
                        0, @batch_id, s.bronze_id, s.row_hash)
            OUTPUT $action INTO #actions (action_name);

            -- Source deletes (CDC 'D')
            UPDATE t
            SET t.is_deleted = 1, t.dwh_batch_id = @batch_id, t.dwh_source_bronze_id = d.bronze_id, t.dwh_update_date = SYSDATETIME()
            FROM silver.crm_cust_info AS t
            JOIN #validated AS d ON d.cst_id = t.cst_id
            WHERE d.is_delete = 1 AND t.is_deleted = 0;
            SET @rows_deleted = @@ROWCOUNT;

            -- Keys that disappeared from a full snapshot
            IF @snap IS NOT NULL
            BEGIN
                UPDATE t
                SET t.is_deleted = 1, t.dwh_batch_id = @batch_id, t.dwh_update_date = SYSDATETIME()
                FROM silver.crm_cust_info AS t
                WHERE t.is_deleted = 0
                  AND NOT EXISTS (SELECT 1 FROM bronze.crm_cust_info AS b
                                  WHERE b.bronze_id >= @snap AND b.bronze_id <= @to AND b.cst_id = t.cst_id);
                SET @rows_deleted += @@ROWCOUNT;
            END;

            EXEC etl.usp_check_fault_injection @point = N'SILVER:silver.crm_cust_info';
            EXEC etl.usp_set_watermark @watermark_name = @wm, @watermark_type = N'BIGINT', @value_bigint = @to, @batch_id = @batch_id;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;

    SELECT @rows_inserted = ISNULL(SUM(CASE WHEN action_name = N'INSERT' THEN 1 ELSE 0 END), 0),
           @rows_updated  = ISNULL(SUM(CASE WHEN action_name = N'UPDATE' THEN 1 ELSE 0 END), 0)
    FROM #actions;

    SET @message = CONCAT(N'Bronze ids ', @from + 1, N'-', @to, CASE WHEN @snap IS NOT NULL THEN N' (includes full snapshot)' ELSE N'' END, N'.');
END;
GO

-- =============================================================================
-- silver.usp_load_crm_prd_info
-- =============================================================================
CREATE OR ALTER PROCEDURE silver.usp_load_crm_prd_info
    @batch_id      INT,
    @rows_read     BIGINT = 0 OUTPUT,
    @rows_inserted BIGINT = 0 OUTPUT,
    @rows_updated  BIGINT = 0 OUTPUT,
    @rows_deleted  BIGINT = 0 OUTPUT,
    @rows_rejected BIGINT = 0 OUTPUT,
    @message       NVARCHAR(1000) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SELECT @rows_read = 0, @rows_inserted = 0, @rows_updated = 0, @rows_deleted = 0, @rows_rejected = 0, @message = NULL;

    DECLARE @wm NVARCHAR(200) = N'silver:bronze.crm_prd_info', @from BIGINT, @to BIGINT, @snap BIGINT;

    EXEC etl.usp_get_bronze_window N'bronze.crm_prd_info', @wm, @from OUTPUT, @to OUTPUT, @snap OUTPUT, @rows_read OUTPUT;
    IF @to <= @from BEGIN SET @message = N'No new Bronze rows.'; RETURN; END;

    SELECT b.bronze_id, b.change_operation, b.prd_id, b.prd_key, b.prd_nm, b.prd_cost, b.prd_line, b.prd_start_dt, b.prd_end_dt
    INTO #latest
    FROM (
        SELECT x.*, rn = ROW_NUMBER() OVER (PARTITION BY x.prd_id ORDER BY x.bronze_id DESC)
        FROM bronze.crm_prd_info AS x
        WHERE x.bronze_id > @from AND x.bronze_id <= @to
          AND x.change_operation <> 'B'
          AND (@snap IS NULL OR x.bronze_id >= @snap)
    ) AS b
    WHERE b.rn = 1;

    SELECT
        l.bronze_id,
        l.prd_id,
        is_delete = CASE WHEN l.change_operation = 'D' THEN 1 ELSE 0 END,
        c.cat_id, c.prd_key, c.prd_nm, c.prd_cost, c.prd_line, c.prd_start_dt,
        rejection_reason = CASE
            WHEN l.change_operation = 'D'          THEN NULL
            WHEN c.raw_key IS NULL OR LEN(c.raw_key) < 7 OR SUBSTRING(c.raw_key, 6, 1) <> N'-'
                                                   THEN N'INVALID_PRODUCT_KEY'
            WHEN l.prd_cost < 0                    THEN N'NEGATIVE_PRODUCT_COST'
            WHEN c.prd_start_dt IS NULL            THEN N'MISSING_START_DATE'
            ELSE NULL END,
        row_hash = HASHBYTES('SHA2_256', CONCAT(
            ISNULL(c.cat_id, N'~'), N'|', ISNULL(c.prd_key, N'~'), N'|', ISNULL(c.prd_nm, N'~'), N'|',
            ISNULL(CAST(c.prd_cost AS NVARCHAR(20)), N'~'), N'|', c.prd_line, N'|',
            ISNULL(CONVERT(NVARCHAR(10), c.prd_start_dt, 23), N'~'))),
        record_data = (SELECT l.prd_id, l.prd_key, l.prd_nm, l.prd_cost, l.prd_line, l.prd_start_dt, l.prd_end_dt,
                              l.change_operation FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES)
    INTO #validated
    FROM #latest AS l
    CROSS APPLY (SELECT raw_key = NULLIF(UPPER(TRIM(l.prd_key)), N'')) AS k
    CROSS APPLY (
        SELECT
            k.raw_key,
            cat_id       = REPLACE(SUBSTRING(k.raw_key, 1, 5), N'-', N'_'),     -- category id from the key prefix
            prd_key      = SUBSTRING(k.raw_key, 7, LEN(k.raw_key)),            -- product number without category
            prd_nm       = NULLIF(TRIM(l.prd_nm), N''),
            prd_cost     = ISNULL(l.prd_cost, 0),
            prd_line     = CASE UPPER(TRIM(l.prd_line))
                               WHEN N'M' THEN N'Mountain' WHEN N'R' THEN N'Road'
                               WHEN N'S' THEN N'Other Sales' WHEN N'T' THEN N'Touring'
                               ELSE N'n/a' END,
            prd_start_dt = l.prd_start_dt
    ) AS c;

    INSERT INTO silver.rejected_records (batch_id, rejection_stage, source_table, source_record_id, record_data, rejection_reason)
    SELECT @batch_id, N'SILVER', N'bronze.crm_prd_info', CAST(bronze_id AS NVARCHAR(50)), record_data, rejection_reason
    FROM #validated
    WHERE rejection_reason IS NOT NULL;
    SET @rows_rejected = @@ROWCOUNT;

    CREATE TABLE #actions (action_name NVARCHAR(10));

    BEGIN TRY
        BEGIN TRANSACTION;

            MERGE silver.crm_prd_info WITH (HOLDLOCK) AS t
            USING (SELECT * FROM #validated WHERE is_delete = 0 AND rejection_reason IS NULL) AS s
                ON t.prd_id = s.prd_id
            WHEN MATCHED AND (t.dwh_row_hash <> s.row_hash OR t.is_deleted = 1) THEN
                UPDATE SET t.cat_id = s.cat_id, t.prd_key = s.prd_key, t.prd_nm = s.prd_nm, t.prd_cost = s.prd_cost,
                           t.prd_line = s.prd_line, t.prd_start_dt = s.prd_start_dt, t.is_deleted = 0,
                           t.dwh_batch_id = @batch_id, t.dwh_source_bronze_id = s.bronze_id,
                           t.dwh_update_date = SYSDATETIME(), t.dwh_row_hash = s.row_hash
            WHEN NOT MATCHED BY TARGET THEN
                INSERT (prd_id, cat_id, prd_key, prd_nm, prd_cost, prd_line, prd_start_dt, is_deleted,
                        dwh_batch_id, dwh_source_bronze_id, dwh_row_hash)
                VALUES (s.prd_id, s.cat_id, s.prd_key, s.prd_nm, s.prd_cost, s.prd_line, s.prd_start_dt, 0,
                        @batch_id, s.bronze_id, s.row_hash)
            OUTPUT $action INTO #actions (action_name);

            UPDATE t
            SET t.is_deleted = 1, t.dwh_batch_id = @batch_id, t.dwh_source_bronze_id = d.bronze_id, t.dwh_update_date = SYSDATETIME()
            FROM silver.crm_prd_info AS t
            JOIN #validated AS d ON d.prd_id = t.prd_id
            WHERE d.is_delete = 1 AND t.is_deleted = 0;
            SET @rows_deleted = @@ROWCOUNT;

            IF @snap IS NOT NULL
            BEGIN
                UPDATE t
                SET t.is_deleted = 1, t.dwh_batch_id = @batch_id, t.dwh_update_date = SYSDATETIME()
                FROM silver.crm_prd_info AS t
                WHERE t.is_deleted = 0
                  AND NOT EXISTS (SELECT 1 FROM bronze.crm_prd_info AS b
                                  WHERE b.bronze_id >= @snap AND b.bronze_id <= @to AND b.prd_id = t.prd_id);
                SET @rows_deleted += @@ROWCOUNT;
            END;

            -- Product versions: end date = day before the next version of the same product starts.
            -- Recalculated after every change because one new version changes the end date of another.
            SELECT p.prd_id,
                   new_end_dt = DATEADD(DAY, -1, LEAD(p.prd_start_dt) OVER (PARTITION BY p.prd_key ORDER BY p.prd_start_dt, p.prd_id))
            INTO #end_dates
            FROM silver.crm_prd_info AS p
            WHERE p.is_deleted = 0;

            UPDATE t
            SET t.prd_end_dt = e.new_end_dt, t.dwh_batch_id = @batch_id, t.dwh_update_date = SYSDATETIME()
            FROM silver.crm_prd_info AS t
            JOIN #end_dates AS e ON e.prd_id = t.prd_id
            WHERE ISNULL(t.prd_end_dt, '99991231') <> ISNULL(e.new_end_dt, '99991231');

            EXEC etl.usp_check_fault_injection @point = N'SILVER:silver.crm_prd_info';
            EXEC etl.usp_set_watermark @watermark_name = @wm, @watermark_type = N'BIGINT', @value_bigint = @to, @batch_id = @batch_id;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;

    SELECT @rows_inserted = ISNULL(SUM(CASE WHEN action_name = N'INSERT' THEN 1 ELSE 0 END), 0),
           @rows_updated  = ISNULL(SUM(CASE WHEN action_name = N'UPDATE' THEN 1 ELSE 0 END), 0)
    FROM #actions;

    SET @message = CONCAT(N'Bronze ids ', @from + 1, N'-', @to, CASE WHEN @snap IS NOT NULL THEN N' (includes full snapshot)' ELSE N'' END, N'.');
END;
GO

-- =============================================================================
-- silver.usp_load_crm_sales_details
-- =============================================================================
CREATE OR ALTER PROCEDURE silver.usp_load_crm_sales_details
    @batch_id      INT,
    @rows_read     BIGINT = 0 OUTPUT,
    @rows_inserted BIGINT = 0 OUTPUT,
    @rows_updated  BIGINT = 0 OUTPUT,
    @rows_deleted  BIGINT = 0 OUTPUT,
    @rows_rejected BIGINT = 0 OUTPUT,
    @message       NVARCHAR(1000) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SELECT @rows_read = 0, @rows_inserted = 0, @rows_updated = 0, @rows_deleted = 0, @rows_rejected = 0, @message = NULL;

    DECLARE @wm NVARCHAR(200) = N'silver:bronze.crm_sales_details', @from BIGINT, @to BIGINT, @snap BIGINT;

    EXEC etl.usp_get_bronze_window N'bronze.crm_sales_details', @wm, @from OUTPUT, @to OUTPUT, @snap OUTPUT, @rows_read OUTPUT;
    IF @to <= @from BEGIN SET @message = N'No new Bronze rows.'; RETURN; END;

    SELECT b.bronze_id, b.change_operation, b.sls_ord_num, b.sls_prd_key, b.sls_cust_id, b.sls_order_dt,
           b.sls_ship_dt, b.sls_due_dt, b.sls_sales, b.sls_quantity, b.sls_price
    INTO #latest
    FROM (
        SELECT x.*, rn = ROW_NUMBER() OVER (PARTITION BY x.sls_ord_num, x.sls_prd_key ORDER BY x.bronze_id DESC)
        FROM bronze.crm_sales_details AS x
        WHERE x.bronze_id > @from AND x.bronze_id <= @to
          AND x.change_operation <> 'B'
          AND (@snap IS NULL OR x.bronze_id >= @snap)
    ) AS b
    WHERE b.rn = 1;

    SELECT
        l.bronze_id,
        l.sls_ord_num,
        l.sls_prd_key,
        is_delete = CASE WHEN l.change_operation = 'D' THEN 1 ELSE 0 END,
        l.sls_cust_id,
        d.sls_order_dt, d.sls_ship_dt, d.sls_due_dt,
        sls_sales    = s.sales,
        sls_quantity = l.sls_quantity,
        sls_price    = s.price,
        rejection_reason = CASE
            WHEN l.change_operation = 'D'                          THEN NULL
            WHEN l.sls_cust_id IS NULL                             THEN N'MISSING_CUSTOMER_ID'
            WHEN l.sls_quantity IS NULL OR l.sls_quantity <= 0     THEN N'INVALID_QUANTITY'
            WHEN s.sales IS NULL OR s.price IS NULL                THEN N'SALES_AND_PRICE_UNUSABLE'
            ELSE NULL END,
        row_hash = HASHBYTES('SHA2_256', CONCAT(
            ISNULL(CAST(l.sls_cust_id AS NVARCHAR(20)), N'~'), N'|',
            ISNULL(CONVERT(NVARCHAR(10), d.sls_order_dt, 23), N'~'), N'|',
            ISNULL(CONVERT(NVARCHAR(10), d.sls_ship_dt, 23), N'~'), N'|',
            ISNULL(CONVERT(NVARCHAR(10), d.sls_due_dt, 23), N'~'), N'|',
            ISNULL(CAST(s.sales AS NVARCHAR(20)), N'~'), N'|',
            ISNULL(CAST(l.sls_quantity AS NVARCHAR(20)), N'~'), N'|',
            ISNULL(CAST(s.price AS NVARCHAR(20)), N'~'))),
        record_data = (SELECT l.sls_ord_num, l.sls_prd_key, l.sls_cust_id, l.sls_order_dt, l.sls_ship_dt, l.sls_due_dt,
                              l.sls_sales, l.sls_quantity, l.sls_price, l.change_operation
                       FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES)
    INTO #validated
    FROM #latest AS l
    -- Integer dates (YYYYMMDD): 0, wrong length or impossible dates become NULL
    CROSS APPLY (
        SELECT
            sls_order_dt = CASE WHEN l.sls_order_dt BETWEEN 19000101 AND 20991231
                                THEN TRY_CONVERT(DATE, CAST(l.sls_order_dt AS CHAR(8)), 112) END,
            sls_ship_dt  = CASE WHEN l.sls_ship_dt  BETWEEN 19000101 AND 20991231
                                THEN TRY_CONVERT(DATE, CAST(l.sls_ship_dt  AS CHAR(8)), 112) END,
            sls_due_dt   = CASE WHEN l.sls_due_dt   BETWEEN 19000101 AND 20991231
                                THEN TRY_CONVERT(DATE, CAST(l.sls_due_dt   AS CHAR(8)), 112) END
    ) AS d
    -- Price: negative prices are sign errors, zero/NULL prices are unknown
    CROSS APPLY (
        SELECT valid_price = CASE WHEN l.sls_price > 0 THEN l.sls_price
                                  WHEN l.sls_price < 0 THEN -l.sls_price END
    ) AS p
    -- Sales = quantity x price when the price is known, otherwise keep a positive sales value;
    -- a missing price is derived from sales / quantity.
    CROSS APPLY (
        SELECT
            sales = CASE WHEN p.valid_price IS NOT NULL AND l.sls_quantity > 0 THEN l.sls_quantity * p.valid_price
                         WHEN l.sls_sales > 0 THEN l.sls_sales END,
            price = COALESCE(p.valid_price,
                             CASE WHEN l.sls_sales > 0 AND l.sls_quantity > 0 THEN l.sls_sales / l.sls_quantity END)
    ) AS s;

    INSERT INTO silver.rejected_records (batch_id, rejection_stage, source_table, source_record_id, record_data, rejection_reason)
    SELECT @batch_id, N'SILVER', N'bronze.crm_sales_details', CAST(bronze_id AS NVARCHAR(50)), record_data, rejection_reason
    FROM #validated
    WHERE rejection_reason IS NOT NULL;
    SET @rows_rejected = @@ROWCOUNT;

    CREATE TABLE #actions (action_name NVARCHAR(10));

    BEGIN TRY
        BEGIN TRANSACTION;

            MERGE silver.crm_sales_details WITH (HOLDLOCK) AS t
            USING (SELECT * FROM #validated WHERE is_delete = 0 AND rejection_reason IS NULL) AS s
                ON t.sls_ord_num = s.sls_ord_num AND t.sls_prd_key = s.sls_prd_key
            WHEN MATCHED AND (t.dwh_row_hash <> s.row_hash OR t.is_deleted = 1) THEN
                UPDATE SET t.sls_cust_id = s.sls_cust_id, t.sls_order_dt = s.sls_order_dt, t.sls_ship_dt = s.sls_ship_dt,
                           t.sls_due_dt = s.sls_due_dt, t.sls_sales = s.sls_sales, t.sls_quantity = s.sls_quantity,
                           t.sls_price = s.sls_price, t.is_deleted = 0,
                           t.dwh_batch_id = @batch_id, t.dwh_source_bronze_id = s.bronze_id,
                           t.dwh_update_date = SYSDATETIME(), t.dwh_row_hash = s.row_hash
            WHEN NOT MATCHED BY TARGET THEN
                INSERT (sls_ord_num, sls_prd_key, sls_cust_id, sls_order_dt, sls_ship_dt, sls_due_dt, sls_sales,
                        sls_quantity, sls_price, is_deleted, dwh_batch_id, dwh_source_bronze_id, dwh_row_hash)
                VALUES (s.sls_ord_num, s.sls_prd_key, s.sls_cust_id, s.sls_order_dt, s.sls_ship_dt, s.sls_due_dt, s.sls_sales,
                        s.sls_quantity, s.sls_price, 0, @batch_id, s.bronze_id, s.row_hash)
            OUTPUT $action INTO #actions (action_name);

            UPDATE t
            SET t.is_deleted = 1, t.dwh_batch_id = @batch_id, t.dwh_source_bronze_id = d.bronze_id, t.dwh_update_date = SYSDATETIME()
            FROM silver.crm_sales_details AS t
            JOIN #validated AS d ON d.sls_ord_num = t.sls_ord_num AND d.sls_prd_key = t.sls_prd_key
            WHERE d.is_delete = 1 AND t.is_deleted = 0;
            SET @rows_deleted = @@ROWCOUNT;

            IF @snap IS NOT NULL
            BEGIN
                UPDATE t
                SET t.is_deleted = 1, t.dwh_batch_id = @batch_id, t.dwh_update_date = SYSDATETIME()
                FROM silver.crm_sales_details AS t
                WHERE t.is_deleted = 0
                  AND NOT EXISTS (SELECT 1 FROM bronze.crm_sales_details AS b
                                  WHERE b.bronze_id >= @snap AND b.bronze_id <= @to
                                    AND b.sls_ord_num = t.sls_ord_num AND b.sls_prd_key = t.sls_prd_key);
                SET @rows_deleted += @@ROWCOUNT;
            END;

            EXEC etl.usp_check_fault_injection @point = N'SILVER:silver.crm_sales_details';
            EXEC etl.usp_set_watermark @watermark_name = @wm, @watermark_type = N'BIGINT', @value_bigint = @to, @batch_id = @batch_id;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;

    SELECT @rows_inserted = ISNULL(SUM(CASE WHEN action_name = N'INSERT' THEN 1 ELSE 0 END), 0),
           @rows_updated  = ISNULL(SUM(CASE WHEN action_name = N'UPDATE' THEN 1 ELSE 0 END), 0)
    FROM #actions;

    SET @message = CONCAT(N'Bronze ids ', @from + 1, N'-', @to, CASE WHEN @snap IS NOT NULL THEN N' (includes full snapshot)' ELSE N'' END, N'.');
END;
GO

-- =============================================================================
-- silver.usp_load_erp_cust_az12
-- =============================================================================
CREATE OR ALTER PROCEDURE silver.usp_load_erp_cust_az12
    @batch_id      INT,
    @rows_read     BIGINT = 0 OUTPUT,
    @rows_inserted BIGINT = 0 OUTPUT,
    @rows_updated  BIGINT = 0 OUTPUT,
    @rows_deleted  BIGINT = 0 OUTPUT,
    @rows_rejected BIGINT = 0 OUTPUT,
    @message       NVARCHAR(1000) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SELECT @rows_read = 0, @rows_inserted = 0, @rows_updated = 0, @rows_deleted = 0, @rows_rejected = 0, @message = NULL;

    DECLARE @wm NVARCHAR(200) = N'silver:bronze.erp_cust_az12', @from BIGINT, @to BIGINT, @snap BIGINT;
    DECLARE @today DATE = CAST(SYSDATETIME() AS DATE);

    EXEC etl.usp_get_bronze_window N'bronze.erp_cust_az12', @wm, @from OUTPUT, @to OUTPUT, @snap OUTPUT, @rows_read OUTPUT;
    IF @to <= @from BEGIN SET @message = N'No new Bronze rows.'; RETURN; END;

    -- Cleaned key: ERP prefixes some customer keys with 'NAS'
    SELECT b.bronze_id, b.change_operation, b.is_deleted, b.cid, b.bdate, b.gen,
           clean_cid = NULLIF(UPPER(CASE WHEN UPPER(TRIM(b.cid)) LIKE N'NAS%' THEN SUBSTRING(TRIM(b.cid), 4, 50) ELSE TRIM(b.cid) END), N'')
    INTO #latest
    FROM (
        SELECT x.*, rn = ROW_NUMBER() OVER (PARTITION BY x.cid ORDER BY x.bronze_id DESC)
        FROM bronze.erp_cust_az12 AS x
        WHERE x.bronze_id > @from AND x.bronze_id <= @to
          AND x.change_operation <> 'B'
          AND (@snap IS NULL OR x.bronze_id >= @snap)
    ) AS b
    WHERE b.rn = 1;

    SELECT
        l.bronze_id,
        cid = l.clean_cid,
        is_delete = CASE WHEN l.change_operation = 'D' OR l.is_deleted = 1 THEN 1 ELSE 0 END,
        c.bdate, c.gen,
        rejection_reason = CASE
            WHEN l.change_operation = 'D' OR l.is_deleted = 1 THEN NULL
            WHEN l.clean_cid IS NULL                            THEN N'MISSING_CUSTOMER_ID'
            WHEN ROW_NUMBER() OVER (PARTITION BY l.clean_cid ORDER BY l.bronze_id DESC) > 1
                                                                THEN N'DUPLICATE_KEY_AFTER_CLEANING'
            ELSE NULL END,
        row_hash = HASHBYTES('SHA2_256', CONCAT(ISNULL(CONVERT(NVARCHAR(10), c.bdate, 23), N'~'), N'|', c.gen)),
        record_data = (SELECT l.cid, l.bdate, l.gen, l.is_deleted, l.change_operation
                       FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES)
    INTO #validated
    FROM #latest AS l
    CROSS APPLY (
        SELECT
            bdate = CASE WHEN l.bdate > @today THEN NULL ELSE l.bdate END,      -- future birthdates are invalid
            gen   = CASE WHEN UPPER(TRIM(l.gen)) IN (N'F', N'FEMALE') THEN N'Female'
                         WHEN UPPER(TRIM(l.gen)) IN (N'M', N'MALE')   THEN N'Male'
                         ELSE N'n/a' END
    ) AS c;

    INSERT INTO silver.rejected_records (batch_id, rejection_stage, source_table, source_record_id, record_data, rejection_reason)
    SELECT @batch_id, N'SILVER', N'bronze.erp_cust_az12', CAST(bronze_id AS NVARCHAR(50)), record_data, rejection_reason
    FROM #validated
    WHERE rejection_reason IS NOT NULL;
    SET @rows_rejected = @@ROWCOUNT;

    CREATE TABLE #actions (action_name NVARCHAR(10));

    BEGIN TRY
        BEGIN TRANSACTION;

            MERGE silver.erp_cust_az12 WITH (HOLDLOCK) AS t
            USING (SELECT * FROM #validated WHERE is_delete = 0 AND rejection_reason IS NULL) AS s
                ON t.cid = s.cid
            WHEN MATCHED AND (t.dwh_row_hash <> s.row_hash OR t.is_deleted = 1) THEN
                UPDATE SET t.bdate = s.bdate, t.gen = s.gen, t.is_deleted = 0,
                           t.dwh_batch_id = @batch_id, t.dwh_source_bronze_id = s.bronze_id,
                           t.dwh_update_date = SYSDATETIME(), t.dwh_row_hash = s.row_hash
            WHEN NOT MATCHED BY TARGET THEN
                INSERT (cid, bdate, gen, is_deleted, dwh_batch_id, dwh_source_bronze_id, dwh_row_hash)
                VALUES (s.cid, s.bdate, s.gen, 0, @batch_id, s.bronze_id, s.row_hash)
            OUTPUT $action INTO #actions (action_name);

            UPDATE t
            SET t.is_deleted = 1, t.dwh_batch_id = @batch_id, t.dwh_source_bronze_id = d.bronze_id, t.dwh_update_date = SYSDATETIME()
            FROM silver.erp_cust_az12 AS t
            JOIN #validated AS d ON d.cid = t.cid
            WHERE d.is_delete = 1 AND t.is_deleted = 0;
            SET @rows_deleted = @@ROWCOUNT;

            IF @snap IS NOT NULL
            BEGIN
                SELECT DISTINCT clean_cid = NULLIF(UPPER(CASE WHEN UPPER(TRIM(b.cid)) LIKE N'NAS%' THEN SUBSTRING(TRIM(b.cid), 4, 50) ELSE TRIM(b.cid) END), N'')
                INTO #snapshot_keys
                FROM bronze.erp_cust_az12 AS b
                WHERE b.bronze_id >= @snap AND b.bronze_id <= @to;

                UPDATE t
                SET t.is_deleted = 1, t.dwh_batch_id = @batch_id, t.dwh_update_date = SYSDATETIME()
                FROM silver.erp_cust_az12 AS t
                WHERE t.is_deleted = 0
                  AND NOT EXISTS (SELECT 1 FROM #snapshot_keys AS k WHERE k.clean_cid = t.cid);
                SET @rows_deleted += @@ROWCOUNT;
            END;

            EXEC etl.usp_check_fault_injection @point = N'SILVER:silver.erp_cust_az12';
            EXEC etl.usp_set_watermark @watermark_name = @wm, @watermark_type = N'BIGINT', @value_bigint = @to, @batch_id = @batch_id;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;

    SELECT @rows_inserted = ISNULL(SUM(CASE WHEN action_name = N'INSERT' THEN 1 ELSE 0 END), 0),
           @rows_updated  = ISNULL(SUM(CASE WHEN action_name = N'UPDATE' THEN 1 ELSE 0 END), 0)
    FROM #actions;

    SET @message = CONCAT(N'Bronze ids ', @from + 1, N'-', @to, CASE WHEN @snap IS NOT NULL THEN N' (includes full snapshot)' ELSE N'' END, N'.');
END;
GO

-- =============================================================================
-- silver.usp_load_erp_loc_a101
-- =============================================================================
CREATE OR ALTER PROCEDURE silver.usp_load_erp_loc_a101
    @batch_id      INT,
    @rows_read     BIGINT = 0 OUTPUT,
    @rows_inserted BIGINT = 0 OUTPUT,
    @rows_updated  BIGINT = 0 OUTPUT,
    @rows_deleted  BIGINT = 0 OUTPUT,
    @rows_rejected BIGINT = 0 OUTPUT,
    @message       NVARCHAR(1000) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SELECT @rows_read = 0, @rows_inserted = 0, @rows_updated = 0, @rows_deleted = 0, @rows_rejected = 0, @message = NULL;

    DECLARE @wm NVARCHAR(200) = N'silver:bronze.erp_loc_a101', @from BIGINT, @to BIGINT, @snap BIGINT;

    EXEC etl.usp_get_bronze_window N'bronze.erp_loc_a101', @wm, @from OUTPUT, @to OUTPUT, @snap OUTPUT, @rows_read OUTPUT;
    IF @to <= @from BEGIN SET @message = N'No new Bronze rows.'; RETURN; END;

    -- Cleaned key: ERP stores customer keys with a dash (AW-00011000)
    SELECT b.bronze_id, b.change_operation, b.is_deleted, b.cid, b.cntry,
           clean_cid = NULLIF(UPPER(REPLACE(TRIM(b.cid), N'-', N'')), N'')
    INTO #latest
    FROM (
        SELECT x.*, rn = ROW_NUMBER() OVER (PARTITION BY x.cid ORDER BY x.bronze_id DESC)
        FROM bronze.erp_loc_a101 AS x
        WHERE x.bronze_id > @from AND x.bronze_id <= @to
          AND x.change_operation <> 'B'
          AND (@snap IS NULL OR x.bronze_id >= @snap)
    ) AS b
    WHERE b.rn = 1;

    SELECT
        l.bronze_id,
        cid = l.clean_cid,
        is_delete = CASE WHEN l.change_operation = 'D' OR l.is_deleted = 1 THEN 1 ELSE 0 END,
        c.cntry,
        rejection_reason = CASE
            WHEN l.change_operation = 'D' OR l.is_deleted = 1 THEN NULL
            WHEN l.clean_cid IS NULL                            THEN N'MISSING_CUSTOMER_ID'
            WHEN ROW_NUMBER() OVER (PARTITION BY l.clean_cid ORDER BY l.bronze_id DESC) > 1
                                                                THEN N'DUPLICATE_KEY_AFTER_CLEANING'
            ELSE NULL END,
        row_hash = HASHBYTES('SHA2_256', c.cntry),
        record_data = (SELECT l.cid, l.cntry, l.is_deleted, l.change_operation
                       FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES)
    INTO #validated
    FROM #latest AS l
    CROSS APPLY (
        SELECT cntry = CASE
                    WHEN UPPER(TRIM(l.cntry)) IN (N'DE', N'GERMANY')                         THEN N'Germany'
                    WHEN UPPER(TRIM(l.cntry)) IN (N'US', N'USA', N'UNITED STATES')           THEN N'United States'
                    WHEN UPPER(TRIM(l.cntry)) IN (N'UK', N'GB', N'UNITED KINGDOM')           THEN N'United Kingdom'
                    WHEN UPPER(TRIM(l.cntry)) IN (N'AU', N'AUSTRALIA')                       THEN N'Australia'
                    WHEN UPPER(TRIM(l.cntry)) IN (N'FR', N'FRANCE')                          THEN N'France'
                    WHEN UPPER(TRIM(l.cntry)) IN (N'CA', N'CANADA')                          THEN N'Canada'
                    WHEN l.cntry IS NULL OR TRIM(l.cntry) = N''                              THEN N'n/a'
                    ELSE TRIM(l.cntry) END
    ) AS c;

    INSERT INTO silver.rejected_records (batch_id, rejection_stage, source_table, source_record_id, record_data, rejection_reason)
    SELECT @batch_id, N'SILVER', N'bronze.erp_loc_a101', CAST(bronze_id AS NVARCHAR(50)), record_data, rejection_reason
    FROM #validated
    WHERE rejection_reason IS NOT NULL;
    SET @rows_rejected = @@ROWCOUNT;

    CREATE TABLE #actions (action_name NVARCHAR(10));

    BEGIN TRY
        BEGIN TRANSACTION;

            MERGE silver.erp_loc_a101 WITH (HOLDLOCK) AS t
            USING (SELECT * FROM #validated WHERE is_delete = 0 AND rejection_reason IS NULL) AS s
                ON t.cid = s.cid
            WHEN MATCHED AND (t.dwh_row_hash <> s.row_hash OR t.is_deleted = 1) THEN
                UPDATE SET t.cntry = s.cntry, t.is_deleted = 0,
                           t.dwh_batch_id = @batch_id, t.dwh_source_bronze_id = s.bronze_id,
                           t.dwh_update_date = SYSDATETIME(), t.dwh_row_hash = s.row_hash
            WHEN NOT MATCHED BY TARGET THEN
                INSERT (cid, cntry, is_deleted, dwh_batch_id, dwh_source_bronze_id, dwh_row_hash)
                VALUES (s.cid, s.cntry, 0, @batch_id, s.bronze_id, s.row_hash)
            OUTPUT $action INTO #actions (action_name);

            UPDATE t
            SET t.is_deleted = 1, t.dwh_batch_id = @batch_id, t.dwh_source_bronze_id = d.bronze_id, t.dwh_update_date = SYSDATETIME()
            FROM silver.erp_loc_a101 AS t
            JOIN #validated AS d ON d.cid = t.cid
            WHERE d.is_delete = 1 AND t.is_deleted = 0;
            SET @rows_deleted = @@ROWCOUNT;

            IF @snap IS NOT NULL
            BEGIN
                SELECT DISTINCT clean_cid = NULLIF(UPPER(REPLACE(TRIM(b.cid), N'-', N'')), N'')
                INTO #snapshot_keys
                FROM bronze.erp_loc_a101 AS b
                WHERE b.bronze_id >= @snap AND b.bronze_id <= @to;

                UPDATE t
                SET t.is_deleted = 1, t.dwh_batch_id = @batch_id, t.dwh_update_date = SYSDATETIME()
                FROM silver.erp_loc_a101 AS t
                WHERE t.is_deleted = 0
                  AND NOT EXISTS (SELECT 1 FROM #snapshot_keys AS k WHERE k.clean_cid = t.cid);
                SET @rows_deleted += @@ROWCOUNT;
            END;

            EXEC etl.usp_check_fault_injection @point = N'SILVER:silver.erp_loc_a101';
            EXEC etl.usp_set_watermark @watermark_name = @wm, @watermark_type = N'BIGINT', @value_bigint = @to, @batch_id = @batch_id;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;

    SELECT @rows_inserted = ISNULL(SUM(CASE WHEN action_name = N'INSERT' THEN 1 ELSE 0 END), 0),
           @rows_updated  = ISNULL(SUM(CASE WHEN action_name = N'UPDATE' THEN 1 ELSE 0 END), 0)
    FROM #actions;

    SET @message = CONCAT(N'Bronze ids ', @from + 1, N'-', @to, CASE WHEN @snap IS NOT NULL THEN N' (includes full snapshot)' ELSE N'' END, N'.');
END;
GO

-- =============================================================================
-- silver.usp_load_erp_px_cat_g1v2
-- =============================================================================
CREATE OR ALTER PROCEDURE silver.usp_load_erp_px_cat_g1v2
    @batch_id      INT,
    @rows_read     BIGINT = 0 OUTPUT,
    @rows_inserted BIGINT = 0 OUTPUT,
    @rows_updated  BIGINT = 0 OUTPUT,
    @rows_deleted  BIGINT = 0 OUTPUT,
    @rows_rejected BIGINT = 0 OUTPUT,
    @message       NVARCHAR(1000) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SELECT @rows_read = 0, @rows_inserted = 0, @rows_updated = 0, @rows_deleted = 0, @rows_rejected = 0, @message = NULL;

    DECLARE @wm NVARCHAR(200) = N'silver:bronze.erp_px_cat_g1v2', @from BIGINT, @to BIGINT, @snap BIGINT;

    EXEC etl.usp_get_bronze_window N'bronze.erp_px_cat_g1v2', @wm, @from OUTPUT, @to OUTPUT, @snap OUTPUT, @rows_read OUTPUT;
    IF @to <= @from BEGIN SET @message = N'No new Bronze rows.'; RETURN; END;

    SELECT b.bronze_id, b.change_operation, b.id, b.cat, b.subcat, b.maintenance
    INTO #latest
    FROM (
        SELECT x.*, rn = ROW_NUMBER() OVER (PARTITION BY x.id ORDER BY x.bronze_id DESC)
        FROM bronze.erp_px_cat_g1v2 AS x
        WHERE x.bronze_id > @from AND x.bronze_id <= @to
          AND x.change_operation <> 'B'
          AND (@snap IS NULL OR x.bronze_id >= @snap)
    ) AS b
    WHERE b.rn = 1;

    SELECT
        l.bronze_id,
        l.id,
        is_delete = CASE WHEN l.change_operation = 'D' THEN 1 ELSE 0 END,
        c.cat, c.subcat, c.maintenance,
        rejection_reason = CASE
            WHEN l.change_operation = 'D'  THEN NULL
            WHEN TRIM(l.id) <> l.id        THEN N'CATEGORY_ID_HAS_SPACES'
            ELSE NULL END,
        row_hash = HASHBYTES('SHA2_256', CONCAT(ISNULL(c.cat, N'~'), N'|', ISNULL(c.subcat, N'~'), N'|', c.maintenance)),
        record_data = (SELECT l.id, l.cat, l.subcat, l.maintenance, l.change_operation
                       FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES)
    INTO #validated
    FROM #latest AS l
    CROSS APPLY (
        SELECT
            cat         = NULLIF(TRIM(l.cat), N''),
            subcat      = NULLIF(TRIM(l.subcat), N''),
            maintenance = CASE WHEN UPPER(TRIM(l.maintenance)) IN (N'YES', N'Y') THEN N'Yes'
                               WHEN UPPER(TRIM(l.maintenance)) IN (N'NO', N'N')  THEN N'No'
                               ELSE N'n/a' END
    ) AS c;

    INSERT INTO silver.rejected_records (batch_id, rejection_stage, source_table, source_record_id, record_data, rejection_reason)
    SELECT @batch_id, N'SILVER', N'bronze.erp_px_cat_g1v2', CAST(bronze_id AS NVARCHAR(50)), record_data, rejection_reason
    FROM #validated
    WHERE rejection_reason IS NOT NULL;
    SET @rows_rejected = @@ROWCOUNT;

    CREATE TABLE #actions (action_name NVARCHAR(10));

    BEGIN TRY
        BEGIN TRANSACTION;

            MERGE silver.erp_px_cat_g1v2 WITH (HOLDLOCK) AS t
            USING (SELECT * FROM #validated WHERE is_delete = 0 AND rejection_reason IS NULL) AS s
                ON t.id = s.id
            WHEN MATCHED AND (t.dwh_row_hash <> s.row_hash OR t.is_deleted = 1) THEN
                UPDATE SET t.cat = s.cat, t.subcat = s.subcat, t.maintenance = s.maintenance, t.is_deleted = 0,
                           t.dwh_batch_id = @batch_id, t.dwh_source_bronze_id = s.bronze_id,
                           t.dwh_update_date = SYSDATETIME(), t.dwh_row_hash = s.row_hash
            WHEN NOT MATCHED BY TARGET THEN
                INSERT (id, cat, subcat, maintenance, is_deleted, dwh_batch_id, dwh_source_bronze_id, dwh_row_hash)
                VALUES (s.id, s.cat, s.subcat, s.maintenance, 0, @batch_id, s.bronze_id, s.row_hash)
            OUTPUT $action INTO #actions (action_name);

            UPDATE t
            SET t.is_deleted = 1, t.dwh_batch_id = @batch_id, t.dwh_source_bronze_id = d.bronze_id, t.dwh_update_date = SYSDATETIME()
            FROM silver.erp_px_cat_g1v2 AS t
            JOIN #validated AS d ON d.id = t.id
            WHERE d.is_delete = 1 AND t.is_deleted = 0;
            SET @rows_deleted = @@ROWCOUNT;

            IF @snap IS NOT NULL
            BEGIN
                UPDATE t
                SET t.is_deleted = 1, t.dwh_batch_id = @batch_id, t.dwh_update_date = SYSDATETIME()
                FROM silver.erp_px_cat_g1v2 AS t
                WHERE t.is_deleted = 0
                  AND NOT EXISTS (SELECT 1 FROM bronze.erp_px_cat_g1v2 AS b
                                  WHERE b.bronze_id >= @snap AND b.bronze_id <= @to AND b.id = t.id);
                SET @rows_deleted += @@ROWCOUNT;
            END;

            EXEC etl.usp_check_fault_injection @point = N'SILVER:silver.erp_px_cat_g1v2';
            EXEC etl.usp_set_watermark @watermark_name = @wm, @watermark_type = N'BIGINT', @value_bigint = @to, @batch_id = @batch_id;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;

    SELECT @rows_inserted = ISNULL(SUM(CASE WHEN action_name = N'INSERT' THEN 1 ELSE 0 END), 0),
           @rows_updated  = ISNULL(SUM(CASE WHEN action_name = N'UPDATE' THEN 1 ELSE 0 END), 0)
    FROM #actions;

    SET @message = CONCAT(N'Bronze ids ', @from + 1, N'-', @to, CASE WHEN @snap IS NOT NULL THEN N' (includes full snapshot)' ELSE N'' END, N'.');
END;
GO
