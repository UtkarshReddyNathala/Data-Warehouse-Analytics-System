# Audit Logging and Monitoring

The pipeline records everything it does. This makes it easy to see what happened in any run, find errors, and trace any number back to where it came from.

## Log tables

| Table | One row for each... | What it records |
|---|---|---|
| `audit.etl_batch` | Pipeline run | Batch ID, start and end time, duration, status (`RUNNING`, `SUCCESS`, `SUCCESS_WITH_WARNINGS`, `FAILED`), error message, parameters used, user, `failed_step_count`, `dq_warning_count`, `dq_critical_count` |
| `audit.etl_step_log` | Table in each stage | Stage, source and target, load type, rows read / added / updated / deleted / rejected, time taken (ms), status, message |
| `audit.etl_error_log` | Error | SQL error number, severity, state, line, procedure, message, the table being processed, batch, step, time |
| `audit.file_ingestion_log` | File load attempt | File name, path, SHA-256 checksum, size, type of change, status, row counts |
| `audit.cdc_control` | CDC table | Last loaded LSN, status, last re-sync and its reason, last error |
| `audit.etl_watermark` | Watermark | Type, value, batch, time |
| `audit.dq_result` | Quality rule in each run | Rows checked, rows failed, percentage, status |
| `audit.perf_measurement` | Speed measurement | Query, BEFORE or AFTER, elapsed time (ms), CPU time (ms), logical reads |

## How errors are handled

Every procedure that writes data follows the same pattern:

```sql
SET XACT_ABORT ON;
BEGIN TRY
    BEGIN TRANSACTION;
        -- write the data
        -- move the watermark
    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;   -- undo everything
    THROW;                                     -- pass the error on, never hide it
END CATCH;
```

The data and the watermark are saved together. If anything goes wrong, both are undone, and the error is passed on.

The error then travels up like this:

1. The procedures that run the loads (`etl.usp_run_metadata_driven_load` and `gold.load_gold`) catch the error once. They write it to `audit.etl_error_log`, mark the step as `FAILED`, and pass the error on.
2. The main pipeline marks the whole run as `FAILED`, closes any step that was still running, releases its lock, and passes the error on again.
3. So whatever started the pipeline (a SQL Server Agent job, a test script or another tool) always sees that it failed.

Only tables set with `is_critical = 0` are allowed to fail without stopping the run.

**Run status rules**

| Status | When |
|---|---|
| `SUCCESS` | Every step worked and no quality rule reported anything |
| `SUCCESS_WITH_WARNINGS` | The run finished, but at least one of these counters is above zero: `failed_step_count` (a non-critical table failed), `dq_warning_count` (a WARNING quality rule failed), `dq_critical_count` (a CRITICAL quality rule failed while `dq_stop_on_critical = 0`) |
| `FAILED` | A critical step or a CRITICAL quality rule failed. The error is passed on |

The three counters are kept separately, so a data warning is never confused with a table that failed to load.

The row counts in `audit.etl_step_log` are exact. They are taken inside each SQL statement (`SET @n = @@ROWCOUNT`) and passed back as OUTPUT parameters.

## Only one run at a time

The pipeline takes a lock with `sp_getapplock` (lock name `DWH_MASTER_PIPELINE`, exclusive, for the session). This stops two runs from working on the same watermarks at the same time.

## Monitoring dashboard

`scripts/monitoring/etl_monitoring_dashboard.sql` contains these queries:

1. Recent pipeline runs
2. The steps of the latest run, with row counts
3. Failed runs, with the SQL error details
4. Slow steps (taking more than twice their usual time)
5. File loads (checksums, skipped duplicate files, failures)
6. CDC: the last loaded position vs the newest captured position, delay in seconds, re-syncs, and how long the capture job takes (`sys.dm_cdc_log_scan_sessions`)
7. All watermarks
8. Rejected rows by table and reason, and tables where more than 1% of rows are rejected
9. Tables that got no new rows in the last 5 successful runs
10. Data quality results of the latest run
11. Row counts compared: source vs Silver vs Gold

## Running on a schedule

Create a SQL Server Agent job with one T-SQL step:

```sql
EXEC DataWarehouse.etl.usp_run_pipeline @return_summary = 0;
```

If the pipeline fails, the job step fails too, so the normal SQL Server Agent alerts will work.
