# Testing

All tests are T-SQL scripts. Each test:

1. changes data in the source tables (the simulated company database),
2. runs the real pipeline,
3. checks that the results are correct.

The tests use a small helper framework (`tests/test_framework.sql`). Every check is saved in `test.test_result`. At the end of each test suite, if any check failed, the suite raises an error (THROW). This means an automated build (CI) job would also fail.

> **Important:** run the tests on a development database only. Each suite cleans up its own test rows (they use keys starting from 99000000, and order numbers starting with `SO_TEST`). Gold keeps the history of these test changes on purpose (closed versions and deleted flags).

## How to run the tests

| Where | How |
|---|---|
| Docker | `./deploy/deploy.sh --test` |
| SSMS | Turn on SQLCMD mode, open `tests/run_all_tests.sql`, add `:setvar RepoRoot "C:\path\to\repo"` at the top, and run it |
| One suite only | Run `tests/test_framework.sql` once, then run any test file |

To see the results:

```sql
SELECT * FROM test.test_run ORDER BY run_id DESC;    -- all test runs
SELECT * FROM test.test_result WHERE passed = 0;     -- checks that failed
```

## What each suite tests

| Suite | File | What it checks |
|---|---|---|
| File ingestion | `ingestion/test_file_ingestion.sql` | An invalid date is rejected and the existing row is kept. An unreadable or blank key pauses all deletes. A duplicate key is handled. A file missing most of its rows is rejected. A real delete works. A failure halfway is undone, and the same file can be loaded again (REPROCESS). An unchanged file is skipped. If CDC cannot capture changes, the run fails without moving the watermark, and the next run loads the data once. |
| Metadata-driven ETL | `metadata_driven_etl/test_metadata_config.sql` | A table can be turned off and on. A wrong watermark column is rejected and the run does not start. Settings for a table that does not exist are rejected. A table can switch from INCREMENTAL to FULL and back without code changes. Tables load in `load_priority` order. |
| CDC | `cdc/test_cdc_capture.sql` | Inserts, updates (before and after values) and deletes. Several changes between two runs. The right range of changes is read. When changes are lost (retention gap), a full copy is taken. |
| Incremental loading | `incremental_loading/test_incremental_loading.sql` | A run with no changes does nothing. One ERP change gives exactly one row. A new sale is loaded once and linked to the right customer version. A customer that arrives late is linked correctly. |
| SCD Type 2 | `scd_validation/test_scd_type2.sql` | Type 2: the old version is closed, a new key is made, only one version is current, and past sales do not change. Type 1: corrections are written to all versions. All Gold history rules pass. |
| Failure and recovery | `pipeline_tests/test_failure_recovery.sql` | Failures are forced in Silver, Bronze and Gold. Each time: the run is `FAILED`, the error is logged, later steps do not run, watermarks do not move, and the next run loads the data exactly once. A non-critical table failing ends as `SUCCESS_WITH_WARNINGS`. |
| Idempotency | `pipeline_tests/test_idempotency.sql` | Extra runs, and loading the same files again on purpose, change nothing. No duplicate keys are created. |

The file ingestion, failure-and-recovery and idempotency suites read CSV files. So the `data_root` setting must point to the `data` folder (including `data/test_fixtures`).

The file ingestion suite uses a temporary table, `source.test_customer`, with an inactive row in `audit.etl_config`. It removes both at the end.

## Forcing a failure on purpose

To test what happens when something breaks, you can make the pipeline fail at a chosen point:

```sql
EXEC etl.usp_set_setting N'fault_injection_point', N'SILVER:silver.crm_cust_info';
-- ... run the pipeline: it fails at that point, inside the transaction ...
EXEC etl.usp_set_setting N'fault_injection_point', NULL;   -- turn it off again
```

Points you can use: `INGESTION:source.<table>`, `BRONZE:bronze.<table>`, `SILVER:silver.<table>`, `GOLD:gold.dim_customers`, `GOLD:gold.dim_products`, `GOLD:gold.fact_sales`.

## Seeing the latest results

This shows the latest result of every test suite:

```sql
SELECT r.suite_name, t.test_name, t.passed
FROM test.test_result AS t
JOIN test.test_run AS r ON r.run_id = t.run_id
WHERE r.run_id IN (SELECT MAX(run_id) FROM test.test_run GROUP BY suite_name)
ORDER BY r.run_id, t.result_id;
```
