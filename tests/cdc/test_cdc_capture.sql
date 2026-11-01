/*
===============================================================================
Test: SQL Server CDC capture and LSN processing
===============================================================================
In short:
    Tests that CDC captures inserts, updates and deletes, and that each change
    flows through Bronze, Silver and Gold exactly once.

Scenarios:
    1. INSERT in the source table is captured (Bronze 'I'), reaches Silver
       and Gold, and the LSN watermark moves forward.
    2. UPDATE is captured with before/after images ('B' + 'U').
    3. DELETE is captured ('D'); Silver soft-deletes; Gold expires the
       dimension version (history kept).
    4. Several changes to one key between two runs are all captured, and
       Silver ends with the final values.
    5. The processed LSN range never goes beyond the stored watermark.
    6. CDC retention gap: an LSN older than the oldest available LSN is
       detected and a controlled re-synchronisation snapshot is taken.

Prerequisite: deployed database, pipeline already run once.
===============================================================================
*/

USE DataWarehouse;
GO
SET NOCOUNT ON;

EXEC test.usp_begin_run N'CDC capture';

DECLARE @b INT, @n INT, @ok BIT, @txt NVARCHAR(200);
DECLARE @cfg INT = (SELECT config_id FROM audit.etl_config WHERE source_table = N'crm_cust_info');
DECLARE @lsn_before BINARY(10), @lsn_after BINARY(10);

-- Clean leftovers of a previous failed run, then baseline
DELETE FROM source.crm_cust_info WHERE cst_id BETWEEN 99000001 AND 99000009;
EXEC test.usp_run_pipeline @batch_id = @b OUTPUT;
SELECT @lsn_before = last_processed_lsn FROM audit.cdc_control WHERE config_id = @cfg;

-- =============================================================================
-- 1. INSERT
-- =============================================================================
INSERT INTO source.crm_cust_info (cst_id, cst_key, cst_firstname, cst_lastname, cst_marital_status, cst_gndr, cst_create_date)
VALUES (99000001, N'AW99000001', N' Test ', N'Customer', N'S', N'F', '2026-01-01');

EXEC test.usp_run_pipeline @batch_id = @b OUTPUT;

SELECT @n = COUNT(*) FROM bronze.crm_cust_info WHERE batch_id = @b AND cst_id = 99000001 AND change_operation = 'I' AND cdc_start_lsn IS NOT NULL;
EXEC test.usp_assert_equals N'1. INSERT captured in Bronze with operation I and an LSN', 1, @n;

SELECT @txt = cst_firstname FROM silver.crm_cust_info WHERE cst_id = 99000001 AND is_deleted = 0;
EXEC test.usp_assert_equals N'1. INSERT reached Silver (name trimmed)', N'Test', @txt;

SELECT @n = COUNT(*) FROM gold.dim_customers WHERE customer_id = 99000001 AND is_current = 1;
EXEC test.usp_assert_equals N'1. INSERT reached Gold as one current version', 1, @n;

SELECT @lsn_after = last_processed_lsn FROM audit.cdc_control WHERE config_id = @cfg;
SET @ok = CASE WHEN @lsn_after > @lsn_before THEN 1 ELSE 0 END;
EXEC test.usp_assert N'1. LSN watermark moved forward', @ok;

-- =============================================================================
-- 2. UPDATE (Type 2 attribute: marital status)
-- =============================================================================
UPDATE source.crm_cust_info SET cst_marital_status = N'M' WHERE cst_id = 99000001;
EXEC test.usp_run_pipeline @batch_id = @b OUTPUT;

SELECT @n = COUNT(*) FROM bronze.crm_cust_info WHERE batch_id = @b AND cst_id = 99000001 AND change_operation IN ('B', 'U');
EXEC test.usp_assert_equals N'2. UPDATE captured as before (B) and after (U) images', 2, @n;

SELECT @txt = cst_marital_status FROM silver.crm_cust_info WHERE cst_id = 99000001;
EXEC test.usp_assert_equals N'2. Silver shows the new value', N'Married', @txt;

SELECT @n = COUNT(*) FROM gold.dim_customers WHERE customer_id = 99000001;
EXEC test.usp_assert_equals N'2. Gold keeps 2 versions (SCD Type 2)', 2, @n;

-- =============================================================================
-- 3. DELETE
-- =============================================================================
DELETE FROM source.crm_cust_info WHERE cst_id = 99000001;
EXEC test.usp_run_pipeline @batch_id = @b OUTPUT;

SELECT @n = COUNT(*) FROM bronze.crm_cust_info WHERE batch_id = @b AND cst_id = 99000001 AND change_operation = 'D';
EXEC test.usp_assert_equals N'3. DELETE captured in Bronze with operation D', 1, @n;

SELECT @n = COUNT(*) FROM silver.crm_cust_info WHERE cst_id = 99000001 AND is_deleted = 1;
EXEC test.usp_assert_equals N'3. Silver soft-deleted the customer', 1, @n;

SELECT @n = COUNT(*) FROM gold.dim_customers WHERE customer_id = 99000001 AND is_current = 1;
EXEC test.usp_assert_equals N'3. Gold has no current version after the delete', 0, @n;

SELECT @n = COUNT(*) FROM gold.dim_customers WHERE customer_id = 99000001 AND is_deleted = 1 AND expiry_date IS NOT NULL;
EXEC test.usp_assert_equals N'3. Gold history kept: last version expired and flagged deleted', 1, @n;

-- =============================================================================
-- 4. Several changes between two runs
-- =============================================================================
INSERT INTO source.crm_cust_info (cst_id, cst_key, cst_firstname, cst_lastname, cst_marital_status, cst_gndr, cst_create_date)
VALUES (99000002, N'AW99000002', N'Multi', N'Change', N'S', N'M', '2026-01-02');
UPDATE source.crm_cust_info SET cst_firstname = N'Multi2' WHERE cst_id = 99000002;
UPDATE source.crm_cust_info SET cst_lastname  = N'Final'  WHERE cst_id = 99000002;

EXEC test.usp_run_pipeline @batch_id = @b OUTPUT;

SELECT @n = COUNT(*) FROM bronze.crm_cust_info WHERE batch_id = @b AND cst_id = 99000002;
EXEC test.usp_assert_equals N'4. All 3 changes captured (I + 2 x (B,U) = 5 rows)', 5, @n;

SELECT @txt = cst_firstname + N' ' + cst_lastname FROM silver.crm_cust_info WHERE cst_id = 99000002;
EXEC test.usp_assert_equals N'4. Silver holds the final values', N'Multi2 Final', @txt;

-- =============================================================================
-- 5. LSN range
-- =============================================================================
SELECT @lsn_after = last_processed_lsn FROM audit.cdc_control WHERE config_id = @cfg;
SELECT @n = COUNT(*) FROM bronze.crm_cust_info WHERE cdc_start_lsn > @lsn_after;
EXEC test.usp_assert_equals N'5. No Bronze change is newer than the stored LSN watermark', 0, @n;

-- =============================================================================
-- 6. Retention gap -> controlled re-synchronisation
-- =============================================================================
DECLARE @source_rows INT = (SELECT COUNT(*) FROM source.crm_cust_info);

UPDATE audit.cdc_control SET last_processed_lsn = 0x00000000000000000001 WHERE config_id = @cfg;
EXEC test.usp_run_pipeline @batch_id = @b OUTPUT;

SELECT @ok = CASE WHEN last_resync_reason LIKE N'CDC retention gap%' THEN 1 ELSE 0 END
FROM audit.cdc_control WHERE config_id = @cfg;
EXEC test.usp_assert N'6. Retention gap detected', @ok;

SELECT @n = COUNT(*) FROM bronze.crm_cust_info WHERE batch_id = @b AND change_operation = 'S' AND is_full_snapshot = 1;
EXEC test.usp_assert_equals N'6. Re-sync snapshot contains every source row', @source_rows, @n;

SELECT @n = COUNT(*) FROM silver.crm_cust_info WHERE is_deleted = 0;
EXEC test.usp_assert_equals N'6. Silver active rows equal source rows after re-sync', @source_rows, @n;

-- =============================================================================
-- Cleanup
-- =============================================================================
DELETE FROM source.crm_cust_info WHERE cst_id BETWEEN 99000001 AND 99000009;
EXEC test.usp_run_pipeline @batch_id = @b OUTPUT;

EXEC test.usp_end_run;
GO
