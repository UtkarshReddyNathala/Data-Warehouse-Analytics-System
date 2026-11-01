/*
===============================================================================
Test: Idempotency
===============================================================================
In short:
    Tests that running the pipeline again without new data changes nothing and
    never creates duplicates.

Re-running the pipeline must never duplicate data or change history.

Scenarios:
    1. Two extra runs without source changes leave every Silver and Gold
       table exactly as it was (row counts, totals, key ranges).
    2. Forcing the same CSV files to be loaded again changes nothing
       (MERGE only updates rows whose values differ). Needs the CSV files.
    3. No duplicate business keys anywhere in Silver or Gold.
===============================================================================
*/

USE DataWarehouse;
GO
SET NOCOUNT ON;

EXEC test.usp_begin_run N'Idempotency';

DECLARE @b INT, @n INT, @failed BIT;

CREATE TABLE #snapshot (metric NVARCHAR(100) PRIMARY KEY, before_value DECIMAL(38, 2), after_value DECIMAL(38, 2));

EXEC test.usp_run_pipeline @batch_id = @b OUTPUT;

INSERT INTO #snapshot (metric, before_value)
SELECT N'silver.crm_cust_info rows',      COUNT(*) FROM silver.crm_cust_info UNION ALL
SELECT N'silver.crm_prd_info rows',       COUNT(*) FROM silver.crm_prd_info UNION ALL
SELECT N'silver.crm_sales_details rows',  COUNT(*) FROM silver.crm_sales_details UNION ALL
SELECT N'silver.crm_sales_details sales', SUM(CAST(sls_sales AS BIGINT)) FROM silver.crm_sales_details WHERE is_deleted = 0 UNION ALL
SELECT N'silver.erp_cust_az12 rows',      COUNT(*) FROM silver.erp_cust_az12 UNION ALL
SELECT N'silver.erp_loc_a101 rows',       COUNT(*) FROM silver.erp_loc_a101 UNION ALL
SELECT N'silver.erp_px_cat_g1v2 rows',    COUNT(*) FROM silver.erp_px_cat_g1v2 UNION ALL
SELECT N'gold.dim_customers rows',        COUNT(*) FROM gold.dim_customers UNION ALL
SELECT N'gold.dim_customers max key',     MAX(customer_key) FROM gold.dim_customers UNION ALL
SELECT N'gold.dim_products rows',         COUNT(*) FROM gold.dim_products UNION ALL
SELECT N'gold.fact_sales rows',           COUNT(*) FROM gold.fact_sales UNION ALL
SELECT N'gold.fact_sales sales',          SUM(CAST(sales_amount AS BIGINT)) FROM gold.fact_sales WHERE is_deleted = 0 UNION ALL
SELECT N'gold.fact_sales unknown keys',   COUNT(*) FROM gold.fact_sales WHERE customer_key = -1 OR product_key = -1;

-- =============================================================================
-- 1. Two more runs without changes
-- =============================================================================
EXEC test.usp_run_pipeline @batch_id = @b OUTPUT;
EXEC test.usp_run_pipeline @batch_id = @b OUTPUT;

-- =============================================================================
-- 2. Same files loaded again (forced)
-- =============================================================================
SET @failed = 0;
BEGIN TRY
    EXEC test.usp_run_pipeline @batch_id = @b OUTPUT, @run_file_ingestion = 1, @force_file_reload = 1;
END TRY
BEGIN CATCH
    SET @failed = 1;
    PRINT '  (forced file reload failed - check the data_root setting: ' + ERROR_MESSAGE() + ')';
END CATCH;
EXEC test.usp_assert_equals N'2. Forced reload of the same files succeeded', 0, @failed;

SELECT @n = SUM(rows_inserted + rows_updated + rows_deleted) FROM audit.etl_step_log WHERE batch_id = @b AND stage = N'INGESTION';
EXEC test.usp_assert_equals N'2. Reloading identical files changed no source rows', 0, @n;

UPDATE s SET after_value = v.value
FROM #snapshot AS s
JOIN (
    SELECT N'silver.crm_cust_info rows' AS metric,      CAST(COUNT(*) AS DECIMAL(38, 2)) AS value FROM silver.crm_cust_info UNION ALL
    SELECT N'silver.crm_prd_info rows',                 COUNT(*) FROM silver.crm_prd_info UNION ALL
    SELECT N'silver.crm_sales_details rows',            COUNT(*) FROM silver.crm_sales_details UNION ALL
    SELECT N'silver.crm_sales_details sales',           SUM(CAST(sls_sales AS BIGINT)) FROM silver.crm_sales_details WHERE is_deleted = 0 UNION ALL
    SELECT N'silver.erp_cust_az12 rows',                COUNT(*) FROM silver.erp_cust_az12 UNION ALL
    SELECT N'silver.erp_loc_a101 rows',                 COUNT(*) FROM silver.erp_loc_a101 UNION ALL
    SELECT N'silver.erp_px_cat_g1v2 rows',              COUNT(*) FROM silver.erp_px_cat_g1v2 UNION ALL
    SELECT N'gold.dim_customers rows',                  COUNT(*) FROM gold.dim_customers UNION ALL
    SELECT N'gold.dim_customers max key',               MAX(customer_key) FROM gold.dim_customers UNION ALL
    SELECT N'gold.dim_products rows',                   COUNT(*) FROM gold.dim_products UNION ALL
    SELECT N'gold.fact_sales rows',                     COUNT(*) FROM gold.fact_sales UNION ALL
    SELECT N'gold.fact_sales sales',                    SUM(CAST(sales_amount AS BIGINT)) FROM gold.fact_sales WHERE is_deleted = 0 UNION ALL
    SELECT N'gold.fact_sales unknown keys',             COUNT(*) FROM gold.fact_sales WHERE customer_key = -1 OR product_key = -1
) AS v ON v.metric = s.metric;

DECLARE @metric NVARCHAR(100), @before DECIMAL(38, 2), @after DECIMAL(38, 2), @name NVARCHAR(400);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT metric, before_value, after_value FROM #snapshot ORDER BY metric;
OPEN c;
FETCH NEXT FROM c INTO @metric, @before, @after;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @name = N'1+2. Unchanged after re-runs: ' + @metric;
    EXEC test.usp_assert_equals @name, @before, @after;
    FETCH NEXT FROM c INTO @metric, @before, @after;
END;
CLOSE c;
DEALLOCATE c;

-- =============================================================================
-- 3. No duplicate business keys
-- =============================================================================
SELECT @n = COUNT(*) FROM (SELECT order_number, product_number FROM gold.fact_sales GROUP BY order_number, product_number HAVING COUNT(*) > 1) AS x;
EXEC test.usp_assert_equals N'3. No duplicate fact rows', 0, @n;

SELECT @n = COUNT(*) FROM (SELECT customer_id FROM gold.dim_customers WHERE is_current = 1 GROUP BY customer_id HAVING COUNT(*) > 1) AS x;
EXEC test.usp_assert_equals N'3. No customer with two current versions', 0, @n;

SELECT @n = COUNT(*) FROM (SELECT product_number FROM gold.dim_products GROUP BY product_number HAVING COUNT(*) > 1) AS x;
EXEC test.usp_assert_equals N'3. No duplicate products', 0, @n;

EXEC test.usp_end_run;
GO
