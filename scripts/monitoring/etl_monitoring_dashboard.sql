/*
===============================================================================
ETL Monitoring Dashboard
===============================================================================
In short:
    Ready-made queries that show how the pipeline is doing: recent runs, failed
    steps, slow steps, file loads, CDC delay, rejected records and data quality
    results. Run any section on its own.

Script Purpose:
    Queries that show the health of the whole pipeline from the audit tables.
    Each section can be run on its own.

     1. Recent pipeline runs
     2. Steps of the latest run (row counts per table)
     3. Failed pipeline runs and their errors
     4. Long-running steps (slower than 2x their average)
     5. File ingestion status (checksums, skipped duplicates, failures)
     6. CDC processing status and delay (last processed LSN vs latest LSN)
     7. Watermarks
     8. Rejected records by table and reason (rejection rate)
     9. Tables that received no new rows recently
    10. Data quality results of the latest run
    11. Source vs warehouse row count reconciliation

Usage:
    Run after etl.usp_run_pipeline has completed at least once.
===============================================================================
*/

USE DataWarehouse;
GO

-- =============================================================================
-- 1. Recent pipeline runs
-- =============================================================================
SELECT TOP (20)
    batch_id, pipeline_name, start_time, end_time, duration_seconds, status, run_parameters, error_message
FROM audit.etl_batch
ORDER BY batch_id DESC;

-- =============================================================================
-- 2. Steps of the latest run
-- =============================================================================
DECLARE @last_batch INT = (SELECT MAX(batch_id) FROM audit.etl_batch);

SELECT
    step_id, stage, step_name, load_type, status,
    rows_read, rows_inserted, rows_updated, rows_deleted, rows_rejected,
    duration_ms, message
FROM audit.etl_step_log
WHERE batch_id = @last_batch
ORDER BY step_id;

-- =============================================================================
-- 3. Failed runs and their errors
-- =============================================================================
SELECT
    b.batch_id, b.start_time, b.status AS batch_status,
    e.procedure_name, e.object_name, e.error_number, e.error_line, e.error_procedure, e.error_message, e.error_time
FROM audit.etl_batch AS b
JOIN audit.etl_error_log AS e ON e.batch_id = b.batch_id
WHERE b.status = N'FAILED'
ORDER BY e.error_id DESC;

-- =============================================================================
-- 4. Long-running steps (more than 2x the average duration of the same step)
-- =============================================================================
WITH stats AS (
    SELECT step_name, AVG(CAST(duration_ms AS BIGINT)) AS avg_ms, COUNT(*) AS runs
    FROM audit.etl_step_log
    WHERE status IN (N'SUCCESS', N'SKIPPED') AND duration_ms IS NOT NULL
    GROUP BY step_name
)
SELECT TOP (20)
    l.batch_id, l.step_name, l.duration_ms, s.avg_ms, s.runs
FROM audit.etl_step_log AS l
JOIN stats AS s ON s.step_name = l.step_name
WHERE s.runs >= 3
  AND l.duration_ms > 2 * s.avg_ms
  AND l.duration_ms > 1000
ORDER BY l.step_id DESC;

-- =============================================================================
-- 5. File ingestion status
-- =============================================================================
SELECT TOP (50)
    f.file_id, c.source_table, f.file_name, f.change_type, f.status,
    CONVERT(VARCHAR(66), f.file_hash, 1) AS file_sha256, f.file_size,
    f.rows_in_file, f.rows_inserted, f.rows_updated, f.rows_deleted, f.rows_rejected,
    f.received_at, f.processed_at, f.batch_id, f.error_message
FROM audit.file_ingestion_log AS f
JOIN audit.etl_config AS c ON c.config_id = f.config_id
ORDER BY f.file_id DESC;

-- =============================================================================
-- 6. CDC processing status and delay
-- =============================================================================
DECLARE @max_lsn BINARY(10) = sys.fn_cdc_get_max_lsn();

SELECT
    cc.table_name,
    cc.capture_instance,
    CONVERT(VARCHAR(22), cc.last_processed_lsn, 1)                       AS last_processed_lsn,
    sys.fn_cdc_map_lsn_to_time(cc.last_processed_lsn)                     AS last_processed_lsn_time,
    CONVERT(VARCHAR(22), @max_lsn, 1)                                    AS latest_captured_lsn,
    sys.fn_cdc_map_lsn_to_time(@max_lsn)                                  AS latest_captured_lsn_time,
    DATEDIFF(SECOND, sys.fn_cdc_map_lsn_to_time(cc.last_processed_lsn),
                     sys.fn_cdc_map_lsn_to_time(@max_lsn))               AS processing_delay_seconds,
    cc.status, cc.last_processed_at, cc.last_resync_at, cc.last_resync_reason, cc.last_error
FROM audit.cdc_control AS cc
ORDER BY cc.table_name;

-- CDC capture job latency (SQL Server DMV)
SELECT TOP (10) session_id, start_time, end_time, duration, scan_phase, tran_count, command_count, latency, error_count
FROM sys.dm_cdc_log_scan_sessions
ORDER BY start_time DESC;

-- =============================================================================
-- 7. Watermarks
-- =============================================================================
SELECT
    watermark_name, watermark_type,
    CONVERT(VARCHAR(66), value_binary, 1) AS value_binary,
    value_datetime, value_bigint, last_batch_id, updated_at
FROM audit.etl_watermark
ORDER BY watermark_name;

-- =============================================================================
-- 8. Rejected records: count and rate per table and reason
-- =============================================================================
SELECT
    r.rejection_stage,
    r.source_table,
    r.rejection_reason,
    COUNT(*)                AS rejected_rows,
    MAX(r.rejected_at)      AS last_rejected_at
FROM silver.rejected_records AS r
GROUP BY r.rejection_stage, r.source_table, r.rejection_reason
ORDER BY rejected_rows DESC;

-- Tables with a high rejection rate in the latest run (> 1% of rows read)
SELECT
    l.stage, l.target_object, l.rows_read, l.rows_rejected,
    CAST(l.rows_rejected * 100.0 / NULLIF(l.rows_read, 0) AS DECIMAL(9, 2)) AS rejection_rate_pct
FROM audit.etl_step_log AS l
WHERE l.batch_id = @last_batch
  AND l.rows_rejected * 100.0 / NULLIF(l.rows_read, 0) > 1;

-- =============================================================================
-- 9. Tables with no new rows in the last 5 successful runs
-- =============================================================================
WITH last_runs AS (
    SELECT TOP (5) batch_id FROM audit.etl_batch WHERE status LIKE N'SUCCESS%' ORDER BY batch_id DESC
)
SELECT
    l.stage, l.target_object,
    SUM(l.rows_inserted + l.rows_updated + l.rows_deleted) AS rows_changed_last_5_runs
FROM audit.etl_step_log AS l
WHERE l.batch_id IN (SELECT batch_id FROM last_runs)
  AND l.stage IN (N'BRONZE', N'SILVER', N'GOLD')
GROUP BY l.stage, l.target_object
HAVING SUM(l.rows_inserted + l.rows_updated + l.rows_deleted) = 0
ORDER BY l.stage, l.target_object;

-- =============================================================================
-- 10. Data quality results of the latest run
-- =============================================================================
SELECT
    layer, rule_name, category, severity, status,
    records_checked, records_failed, failed_pct, error_message
FROM audit.dq_result
WHERE batch_id = @last_batch
ORDER BY CASE status WHEN N'ERROR' THEN 0 WHEN N'FAILED' THEN 1 WHEN N'WARNING' THEN 2 ELSE 3 END, layer, rule_name;

-- =============================================================================
-- 11. Source vs warehouse row counts
-- =============================================================================
SELECT 'crm_cust_info'     AS entity,
       (SELECT COUNT(*) FROM source.crm_cust_info)                                   AS source_rows,
       (SELECT COUNT(*) FROM silver.crm_cust_info WHERE is_deleted = 0)              AS silver_active_rows,
       (SELECT COUNT(*) FROM gold.dim_customers WHERE is_current = 1 AND customer_key <> -1) AS gold_current_rows
UNION ALL
SELECT 'crm_prd_info',
       (SELECT COUNT(*) FROM source.crm_prd_info),
       (SELECT COUNT(*) FROM silver.crm_prd_info WHERE is_deleted = 0),
       (SELECT COUNT(*) FROM gold.dim_products WHERE is_active = 1 AND product_key <> -1)
UNION ALL
SELECT 'crm_sales_details',
       (SELECT COUNT(*) FROM source.crm_sales_details),
       (SELECT COUNT(*) FROM silver.crm_sales_details WHERE is_deleted = 0),
       (SELECT COUNT(*) FROM gold.fact_sales WHERE is_deleted = 0)
UNION ALL
SELECT 'erp_cust_az12',
       (SELECT COUNT(*) FROM source.erp_cust_az12 WHERE is_deleted = 0),
       (SELECT COUNT(*) FROM silver.erp_cust_az12 WHERE is_deleted = 0),
       NULL
UNION ALL
SELECT 'erp_loc_a101',
       (SELECT COUNT(*) FROM source.erp_loc_a101 WHERE is_deleted = 0),
       (SELECT COUNT(*) FROM silver.erp_loc_a101 WHERE is_deleted = 0),
       NULL
UNION ALL
SELECT 'erp_px_cat_g1v2',
       (SELECT COUNT(*) FROM source.erp_px_cat_g1v2),
       (SELECT COUNT(*) FROM silver.erp_px_cat_g1v2 WHERE is_deleted = 0),
       NULL;
GO
