/*
===============================================================================
Test: Failure handling and recovery
===============================================================================
In short:
    Makes a step fail on purpose and tests that the pipeline stops cleanly,
    keeps its place and loads the data exactly once on the next run.

Uses the fault-injection setting to make one step fail on purpose.

Scenarios:
    1. Silver failure  -> batch FAILED, error logged, Silver watermark kept,
                          re-run loads the change exactly once.
    2. Bronze failure  -> CDC LSN watermark kept, no Bronze rows for the failed
                          batch, re-run extracts the change exactly once.
    3. Gold failure    -> fact watermark kept, re-run creates no duplicates.
    4. Non-critical table failure -> logged, the pipeline continues and ends
                          as SUCCESS_WITH_WARNINGS. (Needs the CSV files.)
===============================================================================
*/

USE DataWarehouse;
GO
SET NOCOUNT ON;

EXEC test.usp_begin_run N'Failure and recovery';

DECLARE @b INT, @n INT, @ok BIT, @failed BIT, @txt NVARCHAR(200);
DECLARE @wm_before BIGINT, @wm_after BIGINT, @lsn_before BINARY(10), @lsn_after BINARY(10);
DECLARE @gold_wm_before VARBINARY(32), @gold_wm_after VARBINARY(32);
DECLARE @cfg INT = (SELECT config_id FROM audit.etl_config WHERE source_table = N'crm_cust_info');

EXEC etl.usp_set_setting N'fault_injection_point', NULL;
DELETE FROM source.crm_cust_info WHERE cst_id = 99000020;
DELETE FROM source.crm_sales_details WHERE sls_ord_num = N'SO_TEST_FR';
EXEC test.usp_run_pipeline @batch_id = @b OUTPUT;

-- =============================================================================
-- 1. Silver failure
-- =============================================================================
INSERT INTO source.crm_cust_info (cst_id, cst_key, cst_firstname, cst_lastname, cst_marital_status, cst_gndr, cst_create_date)
VALUES (99000020, N'AW99000020', N'Recovery', N'Test', N'S', N'M', '2026-01-05');

SELECT @wm_before = value_bigint FROM audit.etl_watermark WHERE watermark_name = N'silver:bronze.crm_cust_info';
EXEC etl.usp_set_setting N'fault_injection_point', N'SILVER:silver.crm_cust_info';

SET @failed = 0;
BEGIN TRY EXEC test.usp_run_pipeline @batch_id = @b OUTPUT; END TRY
BEGIN CATCH SET @failed = 1; END CATCH;
EXEC etl.usp_set_setting N'fault_injection_point', NULL;

SET @b = (SELECT MAX(batch_id) FROM audit.etl_batch);
EXEC test.usp_assert N'1. Pipeline raised the Silver failure to the caller', @failed;

SELECT @txt = status FROM audit.etl_batch WHERE batch_id = @b;
EXEC test.usp_assert_equals N'1. Batch marked FAILED', N'FAILED', @txt;

SELECT @n = COUNT(*) FROM audit.etl_error_log WHERE batch_id = @b AND error_message LIKE N'%Injected test failure%';
SET @ok = CASE WHEN @n >= 1 THEN 1 ELSE 0 END;
EXEC test.usp_assert N'1. Error details written to audit.etl_error_log', @ok;

SELECT @n = COUNT(*) FROM audit.etl_step_log WHERE batch_id = @b AND stage = N'GOLD';
EXEC test.usp_assert_equals N'1. Downstream Gold stage did not run', 0, @n;

SELECT @wm_after = value_bigint FROM audit.etl_watermark WHERE watermark_name = N'silver:bronze.crm_cust_info';
EXEC test.usp_assert_equals N'1. Silver watermark unchanged after the failure', @wm_before, @wm_after;

SELECT @n = COUNT(*) FROM silver.crm_cust_info WHERE cst_id = 99000020;
EXEC test.usp_assert_equals N'1. Failed Silver transaction rolled back', 0, @n;

EXEC test.usp_run_pipeline @batch_id = @b OUTPUT;   -- recovery run

SELECT @n = COUNT(*) FROM silver.crm_cust_info WHERE cst_id = 99000020 AND is_deleted = 0;
EXEC test.usp_assert_equals N'1. Re-run loaded the customer exactly once', 1, @n;

SELECT @n = COUNT(*) FROM bronze.crm_cust_info WHERE cst_id = 99000020;
EXEC test.usp_assert_equals N'1. Change extracted to Bronze exactly once (no duplicate on re-run)', 1, @n;

-- =============================================================================
-- 2. Bronze failure
-- =============================================================================
UPDATE source.crm_cust_info SET cst_lastname = N'Recovered' WHERE cst_id = 99000020;

SELECT @lsn_before = last_processed_lsn FROM audit.cdc_control WHERE config_id = @cfg;
EXEC etl.usp_set_setting N'fault_injection_point', N'BRONZE:bronze.crm_cust_info';

SET @failed = 0;
BEGIN TRY EXEC test.usp_run_pipeline @batch_id = @b OUTPUT; END TRY
BEGIN CATCH SET @failed = 1; END CATCH;
EXEC etl.usp_set_setting N'fault_injection_point', NULL;

SET @b = (SELECT MAX(batch_id) FROM audit.etl_batch);
EXEC test.usp_assert N'2. Pipeline raised the Bronze failure', @failed;

SELECT @lsn_after = last_processed_lsn FROM audit.cdc_control WHERE config_id = @cfg;
SET @ok = CASE WHEN @lsn_after = @lsn_before THEN 1 ELSE 0 END;
EXEC test.usp_assert N'2. CDC LSN watermark unchanged after the failure', @ok;

SELECT @n = COUNT(*) FROM bronze.crm_cust_info WHERE batch_id = @b;
EXEC test.usp_assert_equals N'2. No Bronze rows written by the failed batch', 0, @n;

SELECT @txt = status FROM audit.cdc_control WHERE config_id = @cfg;
EXEC test.usp_assert_equals N'2. CDC control row shows FAILED', N'FAILED', @txt;

EXEC test.usp_run_pipeline @batch_id = @b OUTPUT;

SELECT @n = COUNT(*) FROM bronze.crm_cust_info WHERE cst_id = 99000020 AND change_operation = 'U';
EXEC test.usp_assert_equals N'2. Re-run extracted the update exactly once', 1, @n;

SELECT @txt = cst_lastname FROM silver.crm_cust_info WHERE cst_id = 99000020;
EXEC test.usp_assert_equals N'2. Silver has the recovered value', N'Recovered', @txt;

-- =============================================================================
-- 3. Gold failure
-- =============================================================================
INSERT INTO source.crm_sales_details (sls_ord_num, sls_prd_key, sls_cust_id, sls_order_dt, sls_ship_dt, sls_due_dt, sls_sales, sls_quantity, sls_price)
VALUES (N'SO_TEST_FR', N'BK-R93R-62', 99000020, 20140110, 20140117, 20140122, 3578, 1, 3578);

SELECT @gold_wm_before = value_binary FROM audit.etl_watermark WHERE watermark_name = N'gold:silver.crm_sales_details';
EXEC etl.usp_set_setting N'fault_injection_point', N'GOLD:gold.fact_sales';

SET @failed = 0;
BEGIN TRY EXEC test.usp_run_pipeline @batch_id = @b OUTPUT; END TRY
BEGIN CATCH SET @failed = 1; END CATCH;
EXEC etl.usp_set_setting N'fault_injection_point', NULL;

EXEC test.usp_assert N'3. Pipeline raised the Gold failure', @failed;

SELECT @gold_wm_after = value_binary FROM audit.etl_watermark WHERE watermark_name = N'gold:silver.crm_sales_details';
SET @ok = CASE WHEN @gold_wm_after = @gold_wm_before THEN 1 ELSE 0 END;
EXEC test.usp_assert N'3. Gold fact watermark unchanged after the failure', @ok;

SELECT @n = COUNT(*) FROM gold.fact_sales WHERE order_number = N'SO_TEST_FR';
EXEC test.usp_assert_equals N'3. Failed fact load rolled back', 0, @n;

EXEC test.usp_run_pipeline @batch_id = @b OUTPUT;
EXEC test.usp_run_pipeline @batch_id = @b OUTPUT;   -- and once more

SELECT @n = COUNT(*) FROM gold.fact_sales WHERE order_number = N'SO_TEST_FR';
EXEC test.usp_assert_equals N'3. Re-runs created the fact row exactly once', 1, @n;

-- =============================================================================
-- 4. Non-critical failure (requires the CSV files under the data_root setting)
-- =============================================================================
DECLARE @px INT = (SELECT config_id FROM audit.etl_config WHERE source_table = N'erp_px_cat_g1v2');
UPDATE audit.etl_config SET is_critical = 0 WHERE config_id = @px;
EXEC etl.usp_set_setting N'fault_injection_point', N'INGESTION:source.erp_px_cat_g1v2';

SET @failed = 0;
BEGIN TRY EXEC test.usp_run_pipeline @batch_id = @b OUTPUT, @run_file_ingestion = 1, @force_file_reload = 1; END TRY
BEGIN CATCH SET @failed = 1; PRINT '  (scenario 4 error: ' + ERROR_MESSAGE() + ')'; END CATCH;

EXEC etl.usp_set_setting N'fault_injection_point', NULL;
UPDATE audit.etl_config SET is_critical = 1 WHERE config_id = @px;

SET @b = (SELECT MAX(batch_id) FROM audit.etl_batch);
SELECT @txt = status FROM audit.etl_batch WHERE batch_id = @b;
EXEC test.usp_assert_equals N'4. Non-critical failure: run continues and ends with warnings', N'SUCCESS_WITH_WARNINGS', @txt;

SELECT @n = COUNT(*) FROM audit.etl_step_log WHERE batch_id = @b AND stage = N'INGESTION' AND status = N'FAILED';
EXEC test.usp_assert_equals N'4. The failed table step is logged as FAILED', 1, @n;

SELECT @n = failed_step_count FROM audit.etl_batch WHERE batch_id = @b;
EXEC test.usp_assert_equals N'4. Batch records one failed non-critical step', 1, @n;

-- =============================================================================
-- Cleanup
-- =============================================================================
DELETE FROM source.crm_sales_details WHERE sls_ord_num = N'SO_TEST_FR';
DELETE FROM source.crm_cust_info WHERE cst_id = 99000020;
EXEC test.usp_run_pipeline @batch_id = @b OUTPUT;

EXEC test.usp_end_run;
GO
