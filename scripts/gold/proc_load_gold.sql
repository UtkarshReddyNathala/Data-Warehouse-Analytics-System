/*
===============================================================================
Stored Procedures: Load Gold Layer (Silver -> Star Schema)
===============================================================================
In short:
    Loads the Gold star schema from Silver: dates, customers (with history),
    products, then sales. Sales whose customer or product has not arrived yet
    are linked to an 'Unknown' row and fixed on a later run.

Script Purpose:
    gold.usp_load_dim_date        Adds missing calendar days (idempotent).
    gold.usp_load_dim_customers   SCD Type 1 + Type 2 customer dimension.
    gold.usp_load_dim_products    SCD Type 1 product dimension.
    gold.usp_load_fact_sales      Incremental fact load + late-arriving keys.
    gold.load_gold                Runs the four steps in dependency order
                                  (dimensions before facts) with step logging.

SCD rules for gold.dim_customers
    Type 2 (keep history) : country, marital_status
    Type 1 (overwrite)    : first_name, last_name, gender, birthdate,
                            create_date, customer_number
    - A Type 2 change expires the current version (expiry_date = load time,
      is_current = 0) and inserts a new version with a new surrogate key.
    - A Type 1 change corrects ALL versions of the customer (no history).
    - A source delete expires the current version and marks it is_deleted = 1.
      History is never physically removed.
    - The first version of a customer is valid from 1900-01-01, so historical
      sales map to it. Later versions are valid from the load time.

Fact loading
    - Reads only Silver rows changed since the last Gold load
      (ROWVERSION watermark, upper bound = MIN_ACTIVE_ROWVERSION()).
    - The customer version is chosen with the ORDER DATE (point-in-time lookup),
      so historical sales keep the attributes valid when they happened.
    - Unknown customer/product -> key -1. Each run re-checks rows with -1
      keys and fixes them when the dimension member has arrived (late-arriving
      dimension handling).
    - Deleted source sales are flagged (is_deleted = 1), not physically removed.
===============================================================================
*/

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

USE DataWarehouse;
GO

-- =============================================================================
-- gold.usp_load_dim_date
-- =============================================================================
CREATE OR ALTER PROCEDURE gold.usp_load_dim_date
    @start_date    DATE = NULL,
    @end_date      DATE = NULL,
    @rows_inserted BIGINT = 0 OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    -- Cover the default range and every date found in the sales data
    SELECT @start_date = ISNULL(@start_date, '2000-01-01'),
           @end_date   = ISNULL(@end_date,   '2030-12-31');

    SELECT @start_date = CASE WHEN MIN(d) < @start_date THEN MIN(d) ELSE @start_date END,
           @end_date   = CASE WHEN MAX(d) > @end_date   THEN MAX(d) ELSE @end_date END
    FROM (
        SELECT sls_order_dt FROM silver.crm_sales_details
        UNION ALL SELECT sls_ship_dt FROM silver.crm_sales_details
        UNION ALL SELECT sls_due_dt  FROM silver.crm_sales_details
    ) AS x (d);

    ;WITH n AS (
        SELECT TOP (DATEDIFF(DAY, @start_date, @end_date) + 1)
               rn = ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1
        FROM sys.all_objects AS a CROSS JOIN sys.all_objects AS b
    ),
    d AS (
        SELECT full_date = DATEADD(DAY, rn, @start_date) FROM n
    )
    INSERT INTO gold.dim_date (date_key, full_date, year_number, quarter_number, month_number, month_name, year_month,
                               day_of_month, day_of_week, day_name, week_of_year, is_weekend)
    SELECT
        CAST(CONVERT(CHAR(8), d.full_date, 112) AS INT),
        d.full_date,
        YEAR(d.full_date),
        DATEPART(QUARTER, d.full_date),
        MONTH(d.full_date),
        DATENAME(MONTH, d.full_date),
        CONVERT(CHAR(7), d.full_date, 126),
        DAY(d.full_date),
        DATEDIFF(DAY, '19000101', d.full_date) % 7 + 1,           -- 1 = Monday (independent of DATEFIRST)
        DATENAME(WEEKDAY, d.full_date),
        DATEPART(ISO_WEEK, d.full_date),
        CASE WHEN DATEDIFF(DAY, '19000101', d.full_date) % 7 + 1 IN (6, 7) THEN 1 ELSE 0 END
    FROM d
    WHERE NOT EXISTS (SELECT 1 FROM gold.dim_date AS x WHERE x.full_date = d.full_date);

    SET @rows_inserted = @@ROWCOUNT;
END;
GO

-- =============================================================================
-- gold.usp_load_dim_customers  (SCD Type 1 + Type 2)
-- =============================================================================
CREATE OR ALTER PROCEDURE gold.usp_load_dim_customers
    @batch_id      INT,
    @rows_read     BIGINT = 0 OUTPUT,
    @rows_inserted BIGINT = 0 OUTPUT,   -- new versions (new customers + Type 2 changes)
    @rows_updated  BIGINT = 0 OUTPUT,   -- rows corrected by Type 1 changes
    @rows_deleted  BIGINT = 0 OUTPUT,   -- versions expired because of a source delete
    @message       NVARCHAR(1000) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @load_ts DATETIME2(3) = SYSDATETIME();
    DECLARE @type2_changes BIGINT = 0, @new_customers BIGINT = 0;
    SELECT @rows_read = 0, @rows_inserted = 0, @rows_updated = 0, @rows_deleted = 0;

    -- 1. Integrated customer view from the three Silver sources ----------------
    SELECT
        ci.cst_id                                   AS customer_id,
        ci.cst_key                                  AS customer_number,
        ci.cst_firstname                            AS first_name,
        ci.cst_lastname                             AS last_name,
        ISNULL(la.cntry, N'n/a')                    AS country,
        ci.cst_marital_status                       AS marital_status,
        CASE WHEN ci.cst_gndr <> N'n/a' THEN ci.cst_gndr       -- CRM is the master for gender
             ELSE ISNULL(ca.gen, N'n/a') END        AS gender,       -- ERP is the fallback
        ca.bdate                                    AS birthdate,
        ci.cst_create_date                          AS create_date,
        ci.is_deleted
    INTO #src
    FROM silver.crm_cust_info AS ci
    LEFT JOIN silver.erp_cust_az12 AS ca ON ca.cid = ci.cst_key AND ca.is_deleted = 0
    LEFT JOIN silver.erp_loc_a101  AS la ON la.cid = ci.cst_key AND la.is_deleted = 0;

    SET @rows_read = @@ROWCOUNT;

    SELECT s.*,
           scd1_hash = HASHBYTES('SHA2_256', CONCAT(s.customer_number, N'|', ISNULL(s.first_name, N'~'), N'|',
                                 ISNULL(s.last_name, N'~'), N'|', s.gender, N'|',
                                 ISNULL(CONVERT(NVARCHAR(10), s.birthdate, 23), N'~'), N'|',
                                 ISNULL(CONVERT(NVARCHAR(10), s.create_date, 23), N'~'))),
           scd2_hash = HASHBYTES('SHA2_256', CONCAT(s.country, N'|', s.marital_status))
    INTO #src_hashed
    FROM #src AS s;

    CREATE UNIQUE CLUSTERED INDEX IX_src_hashed ON #src_hashed (customer_id);

    BEGIN TRY
        BEGIN TRANSACTION;

            -- 2. Type 1: overwrite corrected attributes on every version -----------
            UPDATE d
            SET d.customer_number = s.customer_number,
                d.first_name      = s.first_name,
                d.last_name       = s.last_name,
                d.gender          = s.gender,
                d.birthdate       = s.birthdate,
                d.create_date     = s.create_date,
                d.scd1_hash       = s.scd1_hash,
                d.dwh_batch_id    = @batch_id,
                d.dwh_update_date = @load_ts
            FROM gold.dim_customers AS d
            JOIN #src_hashed AS s ON s.customer_id = d.customer_id
            WHERE s.is_deleted = 0
              AND d.customer_key <> -1
              AND (d.scd1_hash IS NULL OR d.scd1_hash <> s.scd1_hash);
            SET @rows_updated = @@ROWCOUNT;

            -- 3. Type 2: expire the current version when a tracked attribute changed
            UPDATE d
            SET d.expiry_date     = @load_ts,
                d.is_current      = 0,
                d.dwh_batch_id    = @batch_id,
                d.dwh_update_date = @load_ts
            FROM gold.dim_customers AS d
            JOIN #src_hashed AS s ON s.customer_id = d.customer_id
            WHERE d.is_current = 1
              AND d.customer_key <> -1
              AND s.is_deleted = 0
              AND d.scd2_hash <> s.scd2_hash;
            SET @type2_changes = @@ROWCOUNT;

            -- 4. Source deletes: expire the current version, keep history --------
            UPDATE d
            SET d.expiry_date     = @load_ts,
                d.is_current      = 0,
                d.is_deleted      = 1,
                d.dwh_batch_id    = @batch_id,
                d.dwh_update_date = @load_ts
            FROM gold.dim_customers AS d
            JOIN #src_hashed AS s ON s.customer_id = d.customer_id
            WHERE d.is_current = 1
              AND d.customer_key <> -1
              AND s.is_deleted = 1;
            SET @rows_deleted = @@ROWCOUNT;

            -- 5. New versions: new customers, Type 2 changes, re-activated customers
            INSERT INTO gold.dim_customers (
                customer_id, customer_number, first_name, last_name, country, marital_status, gender,
                birthdate, create_date, effective_date, expiry_date, is_current, is_deleted,
                scd1_hash, scd2_hash, dwh_batch_id, dwh_insert_date, dwh_update_date)
            SELECT
                s.customer_id, s.customer_number, s.first_name, s.last_name, s.country, s.marital_status, s.gender,
                s.birthdate, s.create_date,
                CASE WHEN EXISTS (SELECT 1 FROM gold.dim_customers AS h WHERE h.customer_id = s.customer_id)
                     THEN @load_ts                       -- a new version of a known customer
                     ELSE '1900-01-01' END,              -- first version covers all history
                NULL, 1, 0,
                s.scd1_hash, s.scd2_hash, @batch_id, @load_ts, @load_ts
            FROM #src_hashed AS s
            WHERE s.is_deleted = 0
              AND NOT EXISTS (SELECT 1 FROM gold.dim_customers AS d
                              WHERE d.customer_id = s.customer_id AND d.is_current = 1);
            SET @rows_inserted = @@ROWCOUNT;

            EXEC etl.usp_check_fault_injection @point = N'GOLD:gold.dim_customers';

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;

    SET @new_customers = @rows_inserted - @type2_changes;
    SET @message = CONCAT(N'New customers: ', @new_customers, N', Type 2 versions: ', @type2_changes,
                          N', Type 1 rows corrected: ', @rows_updated, N', expired by delete: ', @rows_deleted, N'.');
END;
GO

-- =============================================================================
-- gold.usp_load_dim_products  (SCD Type 1)
-- =============================================================================
CREATE OR ALTER PROCEDURE gold.usp_load_dim_products
    @batch_id      INT,
    @rows_read     BIGINT = 0 OUTPUT,
    @rows_inserted BIGINT = 0 OUTPUT,
    @rows_updated  BIGINT = 0 OUTPUT,
    @rows_deleted  BIGINT = 0 OUTPUT,   -- products deactivated
    @message       NVARCHAR(1000) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @load_ts DATETIME2(3) = SYSDATETIME();
    SELECT @rows_read = 0, @rows_inserted = 0, @rows_updated = 0, @rows_deleted = 0;

    -- Current version of every product number
    SELECT
        p.prd_id        AS product_id,
        p.prd_key       AS product_number,
        p.prd_nm        AS product_name,
        p.cat_id        AS category_id,
        ISNULL(c.cat, N'n/a')         AS category,
        ISNULL(c.subcat, N'n/a')      AS subcategory,
        ISNULL(c.maintenance, N'n/a') AS maintenance,
        p.prd_cost      AS cost,
        p.prd_line      AS product_line,
        p.prd_start_dt  AS start_date
    INTO #src
    FROM (
        SELECT x.*, rn = ROW_NUMBER() OVER (PARTITION BY x.prd_key ORDER BY x.prd_start_dt DESC, x.prd_id DESC)
        FROM silver.crm_prd_info AS x
        WHERE x.is_deleted = 0 AND x.prd_end_dt IS NULL
    ) AS p
    LEFT JOIN silver.erp_px_cat_g1v2 AS c ON c.id = p.cat_id AND c.is_deleted = 0
    WHERE p.rn = 1;

    SET @rows_read = @@ROWCOUNT;

    SELECT s.*,
           scd1_hash = HASHBYTES('SHA2_256', CONCAT(s.product_id, N'|', ISNULL(s.product_name, N'~'), N'|', s.category_id, N'|',
                                 s.category, N'|', s.subcategory, N'|', s.maintenance, N'|', s.cost, N'|',
                                 s.product_line, N'|', CONVERT(NVARCHAR(10), s.start_date, 23)))
    INTO #src_hashed
    FROM #src AS s;

    CREATE TABLE #actions (action_name NVARCHAR(10), deactivated BIT);

    BEGIN TRY
        BEGIN TRANSACTION;

            MERGE gold.dim_products WITH (HOLDLOCK) AS t
            USING #src_hashed AS s
                ON t.product_number = s.product_number
            WHEN MATCHED AND (t.scd1_hash IS NULL OR t.scd1_hash <> s.scd1_hash OR t.is_active = 0) THEN
                UPDATE SET t.product_id = s.product_id, t.product_name = s.product_name, t.category_id = s.category_id,
                           t.category = s.category, t.subcategory = s.subcategory, t.maintenance = s.maintenance,
                           t.cost = s.cost, t.product_line = s.product_line, t.start_date = s.start_date,
                           t.is_active = 1, t.scd1_hash = s.scd1_hash, t.dwh_batch_id = @batch_id, t.dwh_update_date = @load_ts
            WHEN NOT MATCHED BY TARGET THEN
                INSERT (product_id, product_number, product_name, category_id, category, subcategory, maintenance,
                        cost, product_line, start_date, is_active, scd1_hash, dwh_batch_id, dwh_insert_date, dwh_update_date)
                VALUES (s.product_id, s.product_number, s.product_name, s.category_id, s.category, s.subcategory, s.maintenance,
                        s.cost, s.product_line, s.start_date, 1, s.scd1_hash, @batch_id, @load_ts, @load_ts)
            -- Products without a current version are kept (facts reference them) but deactivated
            WHEN NOT MATCHED BY SOURCE AND t.product_key <> -1 AND t.is_active = 1 THEN
                UPDATE SET t.is_active = 0, t.dwh_batch_id = @batch_id, t.dwh_update_date = @load_ts
            OUTPUT $action, CASE WHEN $action = N'UPDATE' AND inserted.is_active = 0 THEN 1 ELSE 0 END
            INTO #actions (action_name, deactivated);

            EXEC etl.usp_check_fault_injection @point = N'GOLD:gold.dim_products';

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;

    SELECT @rows_inserted = ISNULL(SUM(CASE WHEN action_name = N'INSERT' THEN 1 ELSE 0 END), 0),
           @rows_updated  = ISNULL(SUM(CASE WHEN action_name = N'UPDATE' AND deactivated = 0 THEN 1 ELSE 0 END), 0),
           @rows_deleted  = ISNULL(SUM(CASE WHEN deactivated = 1 THEN 1 ELSE 0 END), 0)
    FROM #actions;

    SET @message = CONCAT(N'Products inserted: ', @rows_inserted, N', updated (Type 1): ', @rows_updated,
                          N', deactivated: ', @rows_deleted, N'.');
END;
GO

-- =============================================================================
-- gold.usp_load_fact_sales  (incremental + late-arriving dimensions)
-- =============================================================================
CREATE OR ALTER PROCEDURE gold.usp_load_fact_sales
    @batch_id      INT,
    @rows_read     BIGINT = 0 OUTPUT,
    @rows_inserted BIGINT = 0 OUTPUT,
    @rows_updated  BIGINT = 0 OUTPUT,
    @rows_deleted  BIGINT = 0 OUTPUT,
    @message       NVARCHAR(1000) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @load_ts DATETIME2(3) = SYSDATETIME();
    DECLARE @wm_name NVARCHAR(200) = N'gold:silver.crm_sales_details';
    DECLARE @lo VARBINARY(32), @lo8 BINARY(8), @hi BINARY(8) = CAST(MIN_ACTIVE_ROWVERSION() AS BINARY(8));
    DECLARE @late_customers BIGINT = 0, @late_products BIGINT = 0;
    SELECT @rows_read = 0, @rows_inserted = 0, @rows_updated = 0, @rows_deleted = 0;

    EXEC etl.usp_get_watermark @watermark_name = @wm_name, @value_binary = @lo OUTPUT;
    SET @lo8 = CAST(ISNULL(@lo, 0x0000000000000000) AS BINARY(8));

    -- 1. Silver rows changed since the last Gold load --------------------------
    SELECT s.sls_ord_num, s.sls_prd_key, s.sls_cust_id, s.sls_order_dt, s.sls_ship_dt, s.sls_due_dt,
           s.sls_sales, s.sls_quantity, s.sls_price, s.is_deleted
    INTO #changed
    FROM silver.crm_sales_details AS s
    WHERE s.dwh_row_version >= @lo8
      AND s.dwh_row_version <  @hi;

    SET @rows_read = @@ROWCOUNT;

    -- 2. Resolve surrogate keys ---------------------------------------------
    SELECT
        c.*,
        customer_key      = ISNULL(cust.customer_key, -1),
        product_key       = ISNULL(prod.product_key, -1),
        order_date_key    = ISNULL(od.date_key, -1),
        shipping_date_key = ISNULL(sd.date_key, -1),
        due_date_key      = ISNULL(dd.date_key, -1)
    INTO #resolved
    FROM #changed AS c
    -- Point-in-time lookup: the customer version valid on the order date.
    -- Fallback: the latest version (order date missing or outside every version).
    OUTER APPLY (
        SELECT TOP (1) d.customer_key
        FROM gold.dim_customers AS d
        WHERE d.customer_id = c.sls_cust_id
          AND d.customer_key <> -1
        ORDER BY CASE WHEN c.sls_order_dt IS NOT NULL
                       AND d.effective_date <= c.sls_order_dt
                       AND (d.expiry_date IS NULL OR d.expiry_date > c.sls_order_dt) THEN 0 ELSE 1 END,
                 d.effective_date DESC
    ) AS cust
    LEFT JOIN gold.dim_products AS prod ON prod.product_number = c.sls_prd_key
    LEFT JOIN gold.dim_date AS od ON od.full_date = c.sls_order_dt
    LEFT JOIN gold.dim_date AS sd ON sd.full_date = c.sls_ship_dt
    LEFT JOIN gold.dim_date AS dd ON dd.full_date = c.sls_due_dt;

    CREATE TABLE #actions (action_name NVARCHAR(10), deleted_now BIT);

    BEGIN TRY
        BEGIN TRANSACTION;

            -- 3. Insert new lines, update corrected lines, flag deleted lines --------
            MERGE gold.fact_sales WITH (HOLDLOCK) AS t
            USING #resolved AS s
                ON t.order_number = s.sls_ord_num AND t.product_number = s.sls_prd_key
            WHEN MATCHED AND (
                    t.is_deleted <> s.is_deleted
                 OR (s.is_deleted = 0 AND EXISTS (
                        SELECT s.sls_cust_id, s.customer_key, s.product_key, s.order_date_key, s.shipping_date_key,
                               s.due_date_key, s.sls_order_dt, s.sls_ship_dt, s.sls_due_dt, s.sls_sales, s.sls_quantity, s.sls_price
                        EXCEPT
                        SELECT t.customer_id, t.customer_key, t.product_key, t.order_date_key, t.shipping_date_key,
                               t.due_date_key, t.order_date, t.shipping_date, t.due_date, t.sales_amount, t.quantity, t.price)))
            THEN UPDATE SET
                t.customer_id = s.sls_cust_id, t.customer_key = s.customer_key, t.product_key = s.product_key,
                t.order_date_key = s.order_date_key, t.shipping_date_key = s.shipping_date_key, t.due_date_key = s.due_date_key,
                t.order_date = s.sls_order_dt, t.shipping_date = s.sls_ship_dt, t.due_date = s.sls_due_dt,
                t.sales_amount = s.sls_sales, t.quantity = s.sls_quantity, t.price = s.sls_price,
                t.is_deleted = s.is_deleted, t.dwh_batch_id = @batch_id, t.dwh_update_date = @load_ts
            WHEN NOT MATCHED BY TARGET AND s.is_deleted = 0 THEN
                INSERT (order_number, product_number, customer_id, product_key, customer_key, order_date_key,
                        shipping_date_key, due_date_key, order_date, shipping_date, due_date, sales_amount,
                        quantity, price, is_deleted, dwh_batch_id, dwh_insert_date, dwh_update_date)
                VALUES (s.sls_ord_num, s.sls_prd_key, s.sls_cust_id, s.product_key, s.customer_key, s.order_date_key,
                        s.shipping_date_key, s.due_date_key, s.sls_order_dt, s.sls_ship_dt, s.sls_due_dt, s.sls_sales,
                        s.sls_quantity, s.sls_price, 0, @batch_id, @load_ts, @load_ts)
            OUTPUT $action, CASE WHEN $action = N'UPDATE' AND inserted.is_deleted = 1 AND deleted.is_deleted = 0 THEN 1 ELSE 0 END
            INTO #actions (action_name, deleted_now);

            -- 4. Late-arriving dimensions: fix rows still pointing to "Unknown" ----
            UPDATE f
            SET f.customer_key = x.customer_key, f.dwh_batch_id = @batch_id, f.dwh_update_date = @load_ts
            FROM gold.fact_sales AS f
            CROSS APPLY (
                SELECT TOP (1) d.customer_key
                FROM gold.dim_customers AS d
                WHERE d.customer_id = f.customer_id
                  AND d.customer_key <> -1
                ORDER BY CASE WHEN f.order_date IS NOT NULL
                               AND d.effective_date <= f.order_date
                               AND (d.expiry_date IS NULL OR d.expiry_date > f.order_date) THEN 0 ELSE 1 END,
                         d.effective_date DESC
            ) AS x
            WHERE f.customer_key = -1
              AND f.customer_id IS NOT NULL;
            SET @late_customers = @@ROWCOUNT;

            UPDATE f
            SET f.product_key = p.product_key, f.dwh_batch_id = @batch_id, f.dwh_update_date = @load_ts
            FROM gold.fact_sales AS f
            JOIN gold.dim_products AS p ON p.product_number = f.product_number AND p.product_key <> -1
            WHERE f.product_key = -1;
            SET @late_products = @@ROWCOUNT;

            EXEC etl.usp_check_fault_injection @point = N'GOLD:gold.fact_sales';

            EXEC etl.usp_set_watermark @watermark_name = @wm_name, @watermark_type = N'ROWVERSION',
                 @value_binary = @hi, @batch_id = @batch_id;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;

    SELECT @rows_inserted = ISNULL(SUM(CASE WHEN action_name = N'INSERT' THEN 1 ELSE 0 END), 0),
           @rows_updated  = ISNULL(SUM(CASE WHEN action_name = N'UPDATE' AND deleted_now = 0 THEN 1 ELSE 0 END), 0)
                            + @late_customers + @late_products,
           @rows_deleted  = ISNULL(SUM(CASE WHEN deleted_now = 1 THEN 1 ELSE 0 END), 0)
    FROM #actions;

    SET @message = CONCAT(N'Changed Silver rows: ', @rows_read, N'. Late-arriving keys resolved: customers ',
                          @late_customers, N', products ', @late_products, N'.');
END;
GO

-- =============================================================================
-- gold.load_gold  (orchestrator: dimensions before facts)
-- =============================================================================
CREATE OR ALTER PROCEDURE gold.load_gold
    @batch_id INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @step_id BIGINT, @r BIGINT, @i BIGINT, @u BIGINT, @d BIGINT, @msg NVARCHAR(1000), @current_step NVARCHAR(100);

    BEGIN TRY
        -- dim_date --------------------------------------------------------------
        SET @current_step = N'gold.dim_date';
        EXEC audit.usp_step_start @batch_id, N'GOLD', N'Load gold.dim_date', N'calendar', N'gold.dim_date', N'FULL', @step_id OUTPUT;
        EXEC gold.usp_load_dim_date @rows_inserted = @i OUTPUT;
        EXEC audit.usp_step_end @step_id, N'SUCCESS', @rows_inserted = @i;

        -- dim_customers -----------------------------------------------------------
        SET @current_step = N'gold.dim_customers';
        EXEC audit.usp_step_start @batch_id, N'GOLD', N'Load gold.dim_customers (SCD1/SCD2)', N'silver.crm_cust_info + erp_cust_az12 + erp_loc_a101',
             N'gold.dim_customers', N'SCD2', @step_id OUTPUT;
        EXEC gold.usp_load_dim_customers @batch_id, @r OUTPUT, @i OUTPUT, @u OUTPUT, @d OUTPUT, @msg OUTPUT;
        EXEC audit.usp_step_end @step_id, N'SUCCESS', @r, @i, @u, @d, 0, @msg;

        -- dim_products --------------------------------------------------------------
        SET @current_step = N'gold.dim_products';
        EXEC audit.usp_step_start @batch_id, N'GOLD', N'Load gold.dim_products (SCD1)', N'silver.crm_prd_info + erp_px_cat_g1v2',
             N'gold.dim_products', N'SCD1', @step_id OUTPUT;
        EXEC gold.usp_load_dim_products @batch_id, @r OUTPUT, @i OUTPUT, @u OUTPUT, @d OUTPUT, @msg OUTPUT;
        EXEC audit.usp_step_end @step_id, N'SUCCESS', @r, @i, @u, @d, 0, @msg;

        -- fact_sales ----------------------------------------------------------------
        SET @current_step = N'gold.fact_sales';
        EXEC audit.usp_step_start @batch_id, N'GOLD', N'Load gold.fact_sales (incremental)', N'silver.crm_sales_details',
             N'gold.fact_sales', N'INCREMENTAL', @step_id OUTPUT;
        EXEC gold.usp_load_fact_sales @batch_id, @r OUTPUT, @i OUTPUT, @u OUTPUT, @d OUTPUT, @msg OUTPUT;
        EXEC audit.usp_step_end @step_id, N'SUCCESS', @r, @i, @u, @d, 0, @msg;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;

        DECLARE @err NVARCHAR(4000) = LEFT(ERROR_MESSAGE(), 4000);
        EXEC audit.usp_log_error @batch_id = @batch_id, @step_id = @step_id, @procedure_name = N'gold.load_gold', @object_name = @current_step;
        EXEC audit.usp_step_end @step_id, N'FAILED', @message = @err;

        THROW;   -- propagate to the master pipeline
    END CATCH;
END;
GO
