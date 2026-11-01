# Incremental Loading

Every stage of the pipeline loads only the data that changed since its last successful run. Each stage keeps its own **watermark**: the last value it loaded (an LSN, ID or ROWVERSION). The next run loads only data after it. The watermark is always saved **in the same transaction** as the data it belongs to, so the data and the watermark can never get out of step.

## How each stage finds what changed

| Stage | How changes are found | Where the watermark is saved |
|---|---|---|
| CSV file → source | A **SHA-256 checksum** of the file. If it changed, `MERGE` updates only rows whose values are different (compared with `EXCEPT`). A row counts as "missing" only if its key is not in the file at all (see `docs/data_quality.md`). | The checksum of the last loaded file (`audit.file_ingestion_log`) |
| source → Bronze, CDC tables | SQL Server's CDC change functions | `last_processed_lsn` (`audit.cdc_control`) |
| source → Bronze, ERP tables | `row_version >= last AND row_version < MIN_ACTIVE_ROWVERSION()` | `bronze:<table>:INCREMENTAL` (`audit.etl_watermark`) |
| source → Bronze, category table | A SHA-256 checksum of the whole table (made with `FOR JSON`) | `bronze:<table>:FULL` |
| Bronze → Silver | `bronze_id` greater than the last processed `bronze_id` | `silver:<bronze table>` |
| Silver → Gold sales | `dwh_row_version >= last AND < MIN_ACTIVE_ROWVERSION()` | `gold:silver.crm_sales_details` |
| Silver → Gold customers and products | A SHA-256 hash of the tracked columns for each customer or product | Saved in the dimension row itself (`scd1_hash`, `scd2_hash`) |

## Why `MIN_ACTIVE_ROWVERSION()` is used

**ROWVERSION** is a number SQL Server updates every time a row changes. It only goes up.

Using the simple "highest rowversion so far" as the watermark can miss rows. A transaction that **started** earlier can **finish** later. Its rows have a smaller number, but they appear after the watermark has already moved past that number.

`MIN_ACTIVE_ROWVERSION()` gives the smallest number still being used by an unfinished transaction. Everything below it is already saved and safe to read. So each run reads: `>= the previous upper limit` and `< the new upper limit`.

## Deletes in tables that use a watermark

A watermark can only see rows that still exist. A deleted row is simply gone, so it would never be noticed.

That is why the ERP source tables use **soft deletes**: they set `is_deleted = 1` and update `modified_at`. This changes the row's rowversion, so the next incremental load picks it up, and Bronze saves it as a `D` (delete) row.

## Silver: each change is processed once

1. Read the Bronze rows between the last processed `bronze_id` and the newest one.
2. Keep only the latest change for each key (`ROW_NUMBER() ... ORDER BY bronze_id DESC`). If one key changed several times between two runs, only its final state is used.
3. Clean and check the data. Rows that fail go to `silver.rejected_records`.
4. Use `MERGE` to:
   - add new keys,
   - update a row only if its cleaned-data hash is different,
   - soft delete the row if the change is a `D`.
5. If a full snapshot is in this batch, soft delete any key that is missing from it.
6. Move the watermark and commit.

## Late-arriving data

Sometimes a sale arrives **before** its customer or product exists in the warehouse. This is how it is handled:

- **Silver** keeps the sale. The "customer or product exists" check is only a WARNING rule, so the sale is not rejected.
- **Gold** saves the sale with `customer_key = -1` or `product_key = -1`. This points to the **Unknown member**, a row with key `-1` in each dimension. The real customer ID and product number are also kept on the sales row.
- **Every Gold load** looks again at sales with `-1` keys, and fixes them as soon as the customer or product arrives.

## How to check it works

Run the pipeline twice. The second run should change nothing:

```sql
EXEC etl.usp_run_pipeline @run_file_ingestion = 0;

SELECT stage, target_object, rows_read, rows_inserted, rows_updated, rows_deleted
FROM audit.etl_step_log
WHERE batch_id = (SELECT MAX(batch_id) FROM audit.etl_batch);
```

This is also tested automatically in `tests/incremental_loading/test_incremental_loading.sql` and `tests/pipeline_tests/test_idempotency.sql`.
