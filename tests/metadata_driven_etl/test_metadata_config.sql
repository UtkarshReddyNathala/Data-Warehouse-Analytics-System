/*
===============================================================================
Test: Metadata-driven ETL configuration
===============================================================================
In short:
    Tests that changing audit.etl_config changes how tables load without
    changing any code, and that wrong settings are rejected.

Scenarios:
    1. Disabling a table in audit.etl_config removes it from the run.
    2. An invalid watermark column is rejected by validation and the pipeline
       refuses to run.
    3. A configuration row for a table that does not exist is rejected.
    4. Changing a table's load type (INCREMENTAL -> FULL) changes how it is
       extracted - without any code change - and switching back resumes the
       incremental watermark.
    5. Tables are processed in load_priority order.
===============================================================================
*/

USE DataWarehouse;
GO
SET NOCOUNT ON;

EXEC test.usp_begin_run N'Metadata-driven ETL';

DECLARE @b INT, @n INT, @ok BIT, @errors INT, @failed BIT, @src_rows INT;
DECLARE @px INT  = (SELECT config_id FROM audit.etl_config WHERE source_table = N'erp_px_cat_g1v2');
DECLARE @loc INT = (SELECT config_id FROM audit.etl_config WHERE source_table = N'erp_loc_a101');

-- =============================================================================
-- 1. Disable / enable a table
-- =============================================================================
UPDATE audit.etl_config SET is_active = 0 WHERE config_id = @px;
EXEC test.usp_run_pipeline @batch_id = @b OUTPUT;

SELECT @n = COUNT(*) FROM audit.etl_step_log WHERE batch_id = @b AND target_object LIKE N'%erp_px_cat_g1v2';
EXEC test.usp_assert_equals N'1. Inactive table is not processed', 0, @n;

UPDATE audit.etl_config SET is_active = 1 WHERE config_id = @px;
EXEC test.usp_run_pipeline @batch_id = @b OUTPUT;

SELECT @n = COUNT(*) FROM audit.etl_step_log WHERE batch_id = @b AND target_object LIKE N'%erp_px_cat_g1v2' AND stage IN (N'BRONZE', N'SILVER');
EXEC test.usp_assert_equals N'1. Re-activated table is processed again (Bronze + Silver)', 2, @n;

-- =============================================================================
-- 2. Invalid watermark column
-- =============================================================================
UPDATE audit.etl_config SET watermark_column = N'does_not_exist' WHERE config_id = @loc;

EXEC etl.usp_validate_config @config_id = @loc, @raise_error = 0, @error_count = @errors OUTPUT;
SET @ok = CASE WHEN @errors > 0 THEN 1 ELSE 0 END;
EXEC test.usp_assert N'2. Validation reports the invalid watermark column', @ok;

SET @failed = 0;
BEGIN TRY
    EXEC test.usp_run_pipeline @batch_id = @b OUTPUT;
END TRY
BEGIN CATCH
    SET @failed = 1;
END CATCH;
EXEC test.usp_assert N'2. Pipeline refuses to run with an invalid configuration', @failed;

SELECT @ok = CASE WHEN status = N'FAILED' THEN 1 ELSE 0 END
FROM audit.etl_batch WHERE batch_id = (SELECT MAX(batch_id) FROM audit.etl_batch);
EXEC test.usp_assert N'2. The refused run is recorded as FAILED', @ok;

UPDATE audit.etl_config SET watermark_column = N'row_version' WHERE config_id = @loc;

-- =============================================================================
-- 3. Configuration for a table that does not exist
-- =============================================================================
INSERT INTO audit.etl_config (source_system, source_table, target_table, load_type, primary_key_columns,
                              silver_table, silver_procedure, is_active, load_priority)
VALUES (N'ERP', N'erp_missing_table', N'erp_missing_table', N'FULL', N'id',
        N'erp_missing_table', N'usp_load_erp_missing_table', 0, 999);
DECLARE @bad INT = SCOPE_IDENTITY();

EXEC etl.usp_validate_config @config_id = @bad, @raise_error = 0, @error_count = @errors OUTPUT;
SET @ok = CASE WHEN @errors >= 4 THEN 1 ELSE 0 END;   -- source, bronze, silver table and procedure missing
EXEC test.usp_assert N'3. Missing source/Bronze/Silver objects are reported', @ok;

DELETE FROM audit.etl_config WHERE config_id = @bad;

-- =============================================================================
-- 4. Change load type without code changes
-- =============================================================================
UPDATE audit.etl_config SET load_type = N'FULL', watermark_column = NULL WHERE config_id = @loc;

EXEC etl.usp_validate_config @config_id = @loc, @raise_error = 0, @error_count = @errors OUTPUT;
EXEC test.usp_assert_equals N'4. FULL configuration is valid', 0, @errors;

-- force a content change so the FULL fingerprint differs from any earlier one
UPDATE source.erp_loc_a101 SET cntry = N'DE', modified_at = SYSDATETIME() WHERE cid = N'AW-00011001';
SELECT @src_rows = COUNT(*) FROM source.erp_loc_a101;

EXEC test.usp_run_pipeline @batch_id = @b OUTPUT;

SELECT @n = COUNT(*) FROM bronze.erp_loc_a101 WHERE batch_id = @b AND is_full_snapshot = 1;
EXEC test.usp_assert_equals N'4. FULL load type takes a complete snapshot', @src_rows, @n;

UPDATE audit.etl_config SET load_type = N'INCREMENTAL', watermark_column = N'row_version' WHERE config_id = @loc;
UPDATE source.erp_loc_a101 SET cntry = N'Australia', modified_at = SYSDATETIME() WHERE cid = N'AW-00011001';
EXEC test.usp_run_pipeline @batch_id = @b OUTPUT;

SELECT @n = COUNT(*) FROM bronze.erp_loc_a101 WHERE batch_id = @b;
SET @ok = CASE WHEN @n BETWEEN 1 AND 10 THEN 1 ELSE 0 END;    -- the earlier incremental watermark is reused
EXEC test.usp_assert N'4. Switching back to INCREMENTAL resumes from its own watermark (no full reload)', @ok;

-- =============================================================================
-- 5. Load order follows load_priority
-- =============================================================================
;WITH steps AS (
    SELECT l.step_id, c.load_priority,
           rn_exec     = ROW_NUMBER() OVER (ORDER BY l.step_id),
           rn_priority = ROW_NUMBER() OVER (ORDER BY c.load_priority, c.config_id)
    FROM audit.etl_step_log AS l
    JOIN audit.etl_config AS c ON l.target_object = c.target_schema + N'.' + c.target_table
    WHERE l.batch_id = @b AND l.stage = N'BRONZE'
)
SELECT @n = COUNT(*) FROM steps WHERE rn_exec <> rn_priority;
EXEC test.usp_assert_equals N'5. Bronze steps ran in load_priority order', 0, @n;

EXEC test.usp_end_run;
GO
