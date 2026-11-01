/*
===============================================================================
Test: File ingestion safety and recovery
===============================================================================
In short:
    Tests that loading CSV files is safe: bad rows are rejected, existing data
    is never lost by mistake, and a failed load can be retried.

Uses the CSV files in data/test_fixtures and a temporary table
source.test_customer, loaded through the real etl.usp_ingest_source_file
procedure (with an INACTIVE configuration row, so the pipeline never touches it).

Scenarios:
    1. First load of a new file.
    2. Ingestion fails halfway (fault injection) -> source unchanged, file FAILED.
       The same file is retried -> processed successfully (REPROCESS).
    3. A row with an invalid date is rejected, and the EXISTING source row with
       that key is preserved (not deleted, not changed).
    4. A row with an unreadable key -> rejected, and deletions are suspended
       (a missing customer is NOT deleted).
   4b. A row with a blank key -> same protection.
    5. Duplicate business key in the file -> last row wins, the other is rejected.
    6. A file with most rows missing -> rejected by the safety limit, source unchanged.
    7. A genuinely removed row -> deleted from the source table.
    8. Same file again -> skipped by checksum.
    9. CDC capture unavailable -> pipeline fails, LSN watermark not advanced,
       and the re-run extracts the change exactly once.

Requires the data_root setting to point to the data folder (with test_fixtures).
===============================================================================
*/

USE DataWarehouse;
GO
SET NOCOUNT ON;

-- -----------------------------------------------------------------------------
-- Setup: temporary landing/source tables and an inactive configuration row
-- -----------------------------------------------------------------------------
DELETE FROM audit.etl_config WHERE source_schema = N'source' AND source_table = N'test_customer';
DELETE FROM silver.rejected_records WHERE source_table = N'source.test_customer';
IF OBJECT_ID(N'landing.vw_test_customer_bulk', N'V') IS NOT NULL DROP VIEW landing.vw_test_customer_bulk;
IF OBJECT_ID(N'landing.test_customer', N'U') IS NOT NULL DROP TABLE landing.test_customer;
IF OBJECT_ID(N'source.test_customer', N'U') IS NOT NULL DROP TABLE source.test_customer;
GO

CREATE TABLE landing.test_customer (
    landing_row_id BIGINT IDENTITY(1, 1) NOT NULL PRIMARY KEY,
    customer_id    NVARCHAR(400) NULL,
    customer_name  NVARCHAR(400) NULL,
    birth_date     NVARCHAR(400) NULL
);
GO
CREATE VIEW landing.vw_test_customer_bulk AS
SELECT customer_id, customer_name, birth_date FROM landing.test_customer;
GO
CREATE TABLE source.test_customer (
    customer_id    INT          NOT NULL PRIMARY KEY,
    customer_name  NVARCHAR(50) NULL,
    birth_date     DATE         NULL
);
GO

EXEC test.usp_begin_run N'File ingestion';

DECLARE @cfg INT, @r BIGINT, @i BIGINT, @u BIGINT, @d BIGINT, @rej BIGINT, @status NVARCHAR(20), @msg NVARCHAR(1000);
DECLARE @n INT, @ok BIT, @failed BIT, @txt NVARCHAR(200), @dt DATE;

INSERT INTO audit.etl_config (source_system, source_schema, source_table, target_table, load_type, primary_key_columns,
                              source_file_path, landing_table, file_date_format, missing_row_action,
                              silver_table, silver_procedure, is_active, is_critical, load_priority)
VALUES (N'CRM', N'source', N'test_customer', N'test_customer', N'FULL', N'customer_id',
        N'test_fixtures/customers_v1_initial.csv', N'test_customer', 'ymd', N'DELETE',
        N'test_customer', N'usp_not_used', 0, 1, 900);
SET @cfg = SCOPE_IDENTITY();

-- =============================================================================
-- 1. First load
-- =============================================================================
EXEC etl.usp_ingest_source_file @batch_id = NULL, @config_id = @cfg,
     @rows_read = @r OUTPUT, @rows_inserted = @i OUTPUT, @rows_updated = @u OUTPUT,
     @rows_deleted = @d OUTPUT, @rows_rejected = @rej OUTPUT, @status = @status OUTPUT, @message = @msg OUTPUT;
EXEC test.usp_assert_equals N'1. First load inserts 5 rows', 5, @i;

-- =============================================================================
-- 2 + 3. Invalid date: fails halfway first, then retried
-- =============================================================================
UPDATE audit.etl_config SET source_file_path = N'test_fixtures/customers_v2_invalid_date.csv' WHERE config_id = @cfg;
EXEC etl.usp_set_setting N'fault_injection_point', N'INGESTION:source.test_customer';

SET @failed = 0;
BEGIN TRY
    EXEC etl.usp_ingest_source_file @batch_id = NULL, @config_id = @cfg,
         @rows_read = @r OUTPUT, @rows_inserted = @i OUTPUT, @rows_updated = @u OUTPUT,
         @rows_deleted = @d OUTPUT, @rows_rejected = @rej OUTPUT, @status = @status OUTPUT, @message = @msg OUTPUT;
END TRY
BEGIN CATCH
    SET @failed = 1;
END CATCH;
EXEC etl.usp_set_setting N'fault_injection_point', NULL;

EXEC test.usp_assert N'2. Ingestion failure is raised', @failed;

SELECT TOP (1) @txt = status FROM audit.file_ingestion_log WHERE config_id = @cfg ORDER BY file_id DESC;
EXEC test.usp_assert_equals N'2. Failed file is logged as FAILED', N'FAILED', @txt;

SELECT @txt = customer_name FROM source.test_customer WHERE customer_id = 2;
EXEC test.usp_assert_equals N'2. Source unchanged after the failed load (rolled back)', N'Amit', @txt;

SELECT @n = COUNT(*) FROM silver.rejected_records WHERE source_table = N'source.test_customer';
EXEC test.usp_assert_equals N'2. Rejected rows of the failed load were rolled back too', 0, @n;

-- Retry the same file
EXEC etl.usp_ingest_source_file @batch_id = NULL, @config_id = @cfg,
     @rows_read = @r OUTPUT, @rows_inserted = @i OUTPUT, @rows_updated = @u OUTPUT,
     @rows_deleted = @d OUTPUT, @rows_rejected = @rej OUTPUT, @status = @status OUTPUT, @message = @msg OUTPUT;

SELECT TOP (1) @txt = change_type + N'/' + status FROM audit.file_ingestion_log WHERE config_id = @cfg ORDER BY file_id DESC;
EXEC test.usp_assert_equals N'2. Retried file processed successfully as REPROCESS', N'REPROCESS/SUCCESS', @txt;

EXEC test.usp_assert_equals N'3. Invalid-date row rejected', 1, @rej;

SELECT @n = COUNT(*) FROM silver.rejected_records
WHERE source_table = N'source.test_customer' AND rejection_reason LIKE N'TYPE_CONVERSION_FAILED: birth_date%';
EXEC test.usp_assert_equals N'3. Rejection reason names the bad column', 1, @n;

DECLARE @expected_dt DATE = '1992-03-03';
SELECT @dt = birth_date FROM source.test_customer WHERE customer_id = 3;
EXEC test.usp_assert_equals N'3. Existing row with the invalid record''s key is preserved (old values kept)', @expected_dt, @dt;

EXEC test.usp_assert_equals N'3. Nothing deleted because of an invalid row', 0, @d;

SELECT @txt = customer_name FROM source.test_customer WHERE customer_id = 2;
EXEC test.usp_assert_equals N'3. Valid change in the same file applied', N'Amit Kumar', @txt;

-- =============================================================================
-- 4. Unreadable key -> deletions suspended
-- =============================================================================
UPDATE audit.etl_config SET source_file_path = N'test_fixtures/customers_v3_unreadable_key.csv' WHERE config_id = @cfg;
EXEC etl.usp_ingest_source_file @batch_id = NULL, @config_id = @cfg,
     @rows_read = @r OUTPUT, @rows_inserted = @i OUTPUT, @rows_updated = @u OUTPUT,
     @rows_deleted = @d OUTPUT, @rows_rejected = @rej OUTPUT, @status = @status OUTPUT, @message = @msg OUTPUT;

SELECT @n = COUNT(*) FROM silver.rejected_records
WHERE source_table = N'source.test_customer' AND rejection_reason LIKE N'INVALID_KEY%';
EXEC test.usp_assert_equals N'4. Row with unreadable key rejected as INVALID_KEY', 1, @n;

SELECT @n = COUNT(*) FROM source.test_customer WHERE customer_id = 5;
EXEC test.usp_assert_equals N'4. Missing customer NOT deleted while a key is unreadable', 1, @n;

SET @ok = CASE WHEN @msg LIKE N'%suspended%' THEN 1 ELSE 0 END;
EXEC test.usp_assert N'4. Suspension reported in the load message', @ok, @msg;

-- =============================================================================
-- 4b. Blank key -> deletions suspended as well
-- =============================================================================
UPDATE audit.etl_config SET source_file_path = N'test_fixtures/customers_v3b_blank_key.csv' WHERE config_id = @cfg;
EXEC etl.usp_ingest_source_file @batch_id = NULL, @config_id = @cfg,
     @rows_read = @r OUTPUT, @rows_inserted = @i OUTPUT, @rows_updated = @u OUTPUT,
     @rows_deleted = @d OUTPUT, @rows_rejected = @rej OUTPUT, @status = @status OUTPUT, @message = @msg OUTPUT;

SELECT @n = COUNT(*) FROM silver.rejected_records
WHERE source_table = N'source.test_customer' AND rejection_reason = N'MISSING_KEY';
EXEC test.usp_assert_equals N'4b. Row with a blank key rejected as MISSING_KEY', 1, @n;

EXEC test.usp_assert_equals N'4b. Nothing deleted while a key is blank', 0, @d;

SELECT @n = COUNT(*) FROM source.test_customer WHERE customer_id = 5;
EXEC test.usp_assert_equals N'4b. Customer with the lost key is NOT deleted', 1, @n;

-- =============================================================================
-- 5. Duplicate key in the file
-- =============================================================================
UPDATE audit.etl_config SET source_file_path = N'test_fixtures/customers_v4_duplicate_key.csv' WHERE config_id = @cfg;
EXEC etl.usp_ingest_source_file @batch_id = NULL, @config_id = @cfg,
     @rows_read = @r OUTPUT, @rows_inserted = @i OUTPUT, @rows_updated = @u OUTPUT,
     @rows_deleted = @d OUTPUT, @rows_rejected = @rej OUTPUT, @status = @status OUTPUT, @message = @msg OUTPUT;

EXEC test.usp_assert_equals N'5. One duplicate row rejected', 1, @rej;

SELECT @txt = customer_name FROM source.test_customer WHERE customer_id = 1;
EXEC test.usp_assert_equals N'5. Last occurrence of the duplicate key wins', N'Rahul Sharma', @txt;

SELECT @n = COUNT(*) FROM source.test_customer;
EXEC test.usp_assert_equals N'5. Still one row per key', 5, @n;

-- =============================================================================
-- 6. Most rows missing -> safety limit
-- =============================================================================
UPDATE audit.etl_config SET source_file_path = N'test_fixtures/customers_v5_mostly_missing.csv' WHERE config_id = @cfg;
SET @failed = 0;
BEGIN TRY
    EXEC etl.usp_ingest_source_file @batch_id = NULL, @config_id = @cfg,
         @rows_read = @r OUTPUT, @rows_inserted = @i OUTPUT, @rows_updated = @u OUTPUT,
         @rows_deleted = @d OUTPUT, @rows_rejected = @rej OUTPUT, @status = @status OUTPUT, @message = @msg OUTPUT;
END TRY
BEGIN CATCH
    SET @failed = 1;
END CATCH;

EXEC test.usp_assert N'6. File removing 80% of the rows is rejected', @failed;

SELECT @n = COUNT(*) FROM source.test_customer;
EXEC test.usp_assert_equals N'6. Source table unchanged', 5, @n;

-- =============================================================================
-- 7. Genuine delete
-- =============================================================================
UPDATE audit.etl_config SET source_file_path = N'test_fixtures/customers_v6_one_deleted.csv' WHERE config_id = @cfg;
EXEC etl.usp_ingest_source_file @batch_id = NULL, @config_id = @cfg,
     @rows_read = @r OUTPUT, @rows_inserted = @i OUTPUT, @rows_updated = @u OUTPUT,
     @rows_deleted = @d OUTPUT, @rows_rejected = @rej OUTPUT, @status = @status OUTPUT, @message = @msg OUTPUT;

EXEC test.usp_assert_equals N'7. Customer absent from a valid file is deleted', 1, @d;

SELECT @n = COUNT(*) FROM source.test_customer WHERE customer_id = 5;
EXEC test.usp_assert_equals N'7. Deleted customer is gone from the source', 0, @n;

-- =============================================================================
-- 8. Same file again -> skipped
-- =============================================================================
EXEC etl.usp_ingest_source_file @batch_id = NULL, @config_id = @cfg,
     @rows_read = @r OUTPUT, @rows_inserted = @i OUTPUT, @rows_updated = @u OUTPUT,
     @rows_deleted = @d OUTPUT, @rows_rejected = @rej OUTPUT, @status = @status OUTPUT, @message = @msg OUTPUT;
EXEC test.usp_assert_equals N'8. Unchanged file skipped by checksum', N'SKIPPED_DUPLICATE', @status;

-- =============================================================================
-- 9. CDC capture unavailable
--    A zero-second timeout makes etl.usp_cdc_sync_capture fail exactly as it
--    does when the capture job is not running.
-- =============================================================================
DECLARE @b INT, @lsn_before BINARY(10), @lsn_after BINARY(10), @timeout NVARCHAR(4000);
DECLARE @cust_cfg INT = (SELECT config_id FROM audit.etl_config WHERE source_table = N'crm_cust_info');

DELETE FROM source.crm_cust_info WHERE cst_id = 99000030;
EXEC test.usp_run_pipeline @batch_id = @b OUTPUT;

INSERT INTO source.crm_cust_info (cst_id, cst_key, cst_firstname, cst_lastname, cst_marital_status, cst_gndr, cst_create_date)
VALUES (99000030, N'AW99000030', N'Cdc', N'Down', N'S', N'M', '2026-01-06');

SELECT @lsn_before = last_processed_lsn FROM audit.cdc_control WHERE config_id = @cust_cfg;
SET @timeout = audit.fn_get_setting(N'cdc_capture_timeout_seconds');
EXEC etl.usp_set_setting N'cdc_capture_timeout_seconds', N'0';

SET @failed = 0;
BEGIN TRY EXEC test.usp_run_pipeline @batch_id = @b OUTPUT; END TRY
BEGIN CATCH SET @failed = 1; END CATCH;
EXEC etl.usp_set_setting N'cdc_capture_timeout_seconds', @timeout;

SET @b = (SELECT MAX(batch_id) FROM audit.etl_batch);
EXEC test.usp_assert N'9. Pipeline fails when CDC capture is unavailable', @failed;

SELECT @lsn_after = last_processed_lsn FROM audit.cdc_control WHERE config_id = @cust_cfg;
SET @ok = CASE WHEN @lsn_after = @lsn_before THEN 1 ELSE 0 END;
EXEC test.usp_assert N'9. LSN watermark not advanced', @ok;

SELECT @n = COUNT(*) FROM audit.etl_step_log WHERE batch_id = @b AND stage = N'BRONZE';
EXEC test.usp_assert_equals N'9. Bronze stage did not run', 0, @n;

EXEC test.usp_run_pipeline @batch_id = @b OUTPUT;
SELECT @n = COUNT(*) FROM bronze.crm_cust_info WHERE cst_id = 99000030;
EXEC test.usp_assert_equals N'9. Re-run extracts the change exactly once', 1, @n;

-- -----------------------------------------------------------------------------
-- Cleanup
-- -----------------------------------------------------------------------------
DELETE FROM source.crm_cust_info WHERE cst_id = 99000030;
EXEC test.usp_run_pipeline @batch_id = @b OUTPUT;

DELETE FROM audit.etl_config WHERE config_id = @cfg;
DELETE FROM silver.rejected_records WHERE source_table = N'source.test_customer';

EXEC test.usp_end_run;
GO

DROP VIEW landing.vw_test_customer_bulk;
DROP TABLE landing.test_customer;
DROP TABLE source.test_customer;
GO
