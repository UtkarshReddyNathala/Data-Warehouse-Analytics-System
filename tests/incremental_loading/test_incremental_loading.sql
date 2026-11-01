/*
===============================================================================
Test: Incremental loading
===============================================================================
In short:
    Tests that each run only processes new changes, and that late sales are
    linked to the right customer once the customer arrives.

Scenarios:
    1. Re-running the pipeline without source changes processes nothing
       (no Bronze rows, no Silver/Gold inserts, updates or deletes).
    2. An ERP change (watermark/rowversion table) loads exactly one row and
       creates a new customer version in Gold.
    3. A new sale is loaded once, and is linked to the customer version that
       was valid on the order date (point-in-time lookup).
    4. Late-arriving dimension: a sale for an unknown customer is loaded with
       customer_key = -1 and is fixed automatically when the customer arrives.
===============================================================================
*/

USE DataWarehouse;
GO
SET NOCOUNT ON;

EXEC test.usp_begin_run N'Incremental loading';

DECLARE @b INT, @n BIGINT, @ok BIT, @txt NVARCHAR(200), @key INT, @fact_before BIGINT;

-- Leftovers from a failed previous run
DELETE FROM source.crm_sales_details WHERE sls_ord_num LIKE N'SO_TEST%';
DELETE FROM source.crm_cust_info WHERE cst_id = 99000010;
UPDATE source.erp_loc_a101 SET cntry = N'Australia', modified_at = SYSDATETIME()
WHERE cid = N'AW-00011000' AND cntry <> N'Australia';
EXEC test.usp_run_pipeline @batch_id = @b OUTPUT;

-- =============================================================================
-- 1. No changes -> nothing processed
-- =============================================================================
EXEC test.usp_run_pipeline @batch_id = @b OUTPUT;

SELECT @n = SUM(rows_inserted) FROM audit.etl_step_log WHERE batch_id = @b AND stage = N'BRONZE';
EXEC test.usp_assert_equals N'1. No Bronze rows extracted when nothing changed', 0, @n;

SELECT @n = SUM(rows_inserted + rows_updated + rows_deleted) FROM audit.etl_step_log WHERE batch_id = @b AND stage = N'SILVER';
EXEC test.usp_assert_equals N'1. No Silver changes when nothing changed', 0, @n;

SELECT @n = SUM(rows_inserted + rows_updated + rows_deleted) FROM audit.etl_step_log
WHERE batch_id = @b AND stage = N'GOLD' AND target_object <> N'gold.dim_date';
EXEC test.usp_assert_equals N'1. No Gold changes when nothing changed', 0, @n;

-- =============================================================================
-- 2. ERP incremental change (country -> SCD Type 2 in Gold)
-- =============================================================================
UPDATE source.erp_loc_a101 SET cntry = N'FR', modified_at = SYSDATETIME() WHERE cid = N'AW-00011000';
EXEC test.usp_run_pipeline @batch_id = @b OUTPUT;

SELECT @n = COUNT(*) FROM bronze.erp_loc_a101 WHERE batch_id = @b;
EXEC test.usp_assert_equals N'2. Exactly one changed ERP row extracted (rowversion watermark)', 1, @n;

SELECT @n = rows_updated FROM audit.etl_step_log WHERE batch_id = @b AND target_object = N'silver.erp_loc_a101';
EXEC test.usp_assert_equals N'2. Exactly one Silver row updated', 1, @n;

SELECT @txt = country FROM gold.dim_customers WHERE customer_number = N'AW00011000' AND is_current = 1;
EXEC test.usp_assert_equals N'2. Current Gold version has the new country (code standardised)', N'France', @txt;

-- =============================================================================
-- 3. New sale -> loaded once, point-in-time customer version
-- =============================================================================
SELECT @fact_before = COUNT(*) FROM gold.fact_sales WHERE is_deleted = 0;

INSERT INTO source.crm_sales_details (sls_ord_num, sls_prd_key, sls_cust_id, sls_order_dt, sls_ship_dt, sls_due_dt, sls_sales, sls_quantity, sls_price)
VALUES (N'SO_TEST_1', N'BK-R93R-62', 11000, 20140115, 20140122, 20140127, 3578, 1, 3578);
EXEC test.usp_run_pipeline @batch_id = @b OUTPUT;

SELECT @n = COUNT(*) FROM gold.fact_sales WHERE is_deleted = 0;
SET @fact_before += 1;
EXEC test.usp_assert_equals N'3. Exactly one new fact row', @fact_before, @n;

SELECT @n = rows_read FROM audit.etl_step_log WHERE batch_id = @b AND target_object = N'gold.fact_sales';
EXEC test.usp_assert_equals N'3. Gold fact load read only the changed Silver row', 1, @n;

SELECT @txt = c.country
FROM gold.fact_sales AS f JOIN gold.dim_customers AS c ON c.customer_key = f.customer_key
WHERE f.order_number = N'SO_TEST_1';
EXEC test.usp_assert_equals N'3. 2014 order linked to the 2014 customer version (Australia), not the current one', N'Australia', @txt;

-- =============================================================================
-- 4. Late-arriving customer
-- =============================================================================
INSERT INTO source.crm_sales_details (sls_ord_num, sls_prd_key, sls_cust_id, sls_order_dt, sls_ship_dt, sls_due_dt, sls_sales, sls_quantity, sls_price)
VALUES (N'SO_TEST_2', N'BK-R93R-62', 99000010, 20140116, 20140123, 20140128, 3578, 1, 3578);
EXEC test.usp_run_pipeline @batch_id = @b OUTPUT;

SELECT @key = customer_key FROM gold.fact_sales WHERE order_number = N'SO_TEST_2';
EXEC test.usp_assert_equals N'4. Sale with unknown customer kept with customer_key -1', -1, @key;

INSERT INTO source.crm_cust_info (cst_id, cst_key, cst_firstname, cst_lastname, cst_marital_status, cst_gndr, cst_create_date)
VALUES (99000010, N'AW99000010', N'Late', N'Arrival', N'S', N'F', '2026-01-03');
EXEC test.usp_run_pipeline @batch_id = @b OUTPUT;

SELECT @ok = CASE WHEN f.customer_key <> -1 AND c.customer_id = 99000010 THEN 1 ELSE 0 END
FROM gold.fact_sales AS f JOIN gold.dim_customers AS c ON c.customer_key = f.customer_key
WHERE f.order_number = N'SO_TEST_2';
EXEC test.usp_assert N'4. Late-arriving customer resolved automatically', @ok;

-- =============================================================================
-- Cleanup (restores the CSV values)
-- =============================================================================
DELETE FROM source.crm_sales_details WHERE sls_ord_num LIKE N'SO_TEST%';
DELETE FROM source.crm_cust_info WHERE cst_id = 99000010;
UPDATE source.erp_loc_a101 SET cntry = N'Australia', modified_at = SYSDATETIME() WHERE cid = N'AW-00011000';
EXEC test.usp_run_pipeline @batch_id = @b OUTPUT;

SELECT @n = COUNT(*) FROM gold.fact_sales WHERE order_number LIKE N'SO_TEST%' AND is_deleted = 0;
EXEC test.usp_assert_equals N'Cleanup: deleted test sales are flagged deleted in Gold', 0, @n;

EXEC test.usp_end_run;
GO
