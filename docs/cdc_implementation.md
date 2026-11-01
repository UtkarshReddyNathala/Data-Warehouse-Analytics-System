# Change Data Capture (CDC)

**Change Data Capture (CDC)** is a SQL Server feature that records every insert, update and delete made to a table. The project uses it so that each run loads only the changes since the last run.

## Why there is a "source" database in the middle

CDC watches **tables inside SQL Server**. It reads the database's transaction log (the internal record of every change). It cannot look inside a CSV file. So the project checks for changes at two levels:

| Level | What can change | How the change is found |
|---|---|---|
| File | A CSV file is new, edited or sent again | A **SHA-256 checksum** of the whole file, saved in `audit.file_ingestion_log` |
| Row | A row in the source table is added, changed or deleted | SQL Server CDC for the CRM tables, a **ROWVERSION watermark** for the ERP tables, and a checksum of the whole table for the small category table |

The six CSV files are loaded into `source.*` tables. These tables act like the real CRM and ERP databases of a company, with real primary keys.

The file load uses `MERGE` and only touches rows whose values have really changed. Because of this, CDC only records **real** additions, changes and deletes, not fake ones from reloading the same data.

You can also change the `source.*` tables directly with `INSERT`, `UPDATE` or `DELETE`, just like an application would in a real company.

## Which tables are tracked

In CDC, each tracked table has a **capture instance**. This is the name of its change log.

| Source table | Capture instance | Net changes |
|---|---|---|
| `source.crm_cust_info` | `source_crm_cust_info` | Yes (primary key `cst_id`) |
| `source.crm_prd_info` | `source_crm_prd_info` | Yes (primary key `prd_id`) |
| `source.crm_sales_details` | `source_crm_sales_details` | Yes (primary key `sls_ord_num`, `sls_prd_key`) |
| `source.cdc_heartbeat` | `source_cdc_heartbeat` | A helper table, explained below |

Running `EXEC etl.usp_enable_cdc` does three things:

1. Turns on CDC for the database.
2. Turns on CDC for every table that has `load_type = 'CDC'` in `audit.etl_config`.
3. Records each of these tables in `audit.cdc_control`.

Note: SQL Server reserves the schema name `cdc` for itself, so the project never creates a schema with that name.

**What you need for CDC to work:**

- SQL Server **Developer, Standard or Enterprise** edition.
- **SQL Server Agent** must be running. In Docker this is turned on with `MSSQL_AGENT_ENABLED=true`.
- The database must have a valid owner. `init_database.sql` sets the owner to `sa`.

## Making sure CDC is up to date before loading

CDC does not record changes instantly. A background job reads the transaction log a little later. So before loading, the pipeline runs `etl.usp_cdc_sync_capture` to make sure CDC has caught up:

1. It adds a row with a new unique ID (a GUID) to `source.cdc_heartbeat`. This table is tracked by CDC.
2. It waits until that ID shows up in CDC's change table, `cdc.source_cdc_heartbeat_CT`.
3. CDC reads the log in order. So once the heartbeat row has arrived, every change made before it has also arrived.
4. If the SQL Server Agent job is not running, the pipeline runs one manual scan (`sys.sp_cdc_scan`) itself. If the row still does not arrive within `cdc_capture_timeout_seconds`, the run fails with a clear message.

## How changes are read (`bronze.usp_extract_table`)

Every change in the log has a position number called an **LSN** (Log Sequence Number). The pipeline saves the last LSN it loaded as its **watermark**, and the next run continues from there.

```
last  = audit.cdc_control.last_processed_lsn      -- the watermark
min   = sys.fn_cdc_get_min_lsn(capture_instance)  -- oldest change CDC still has
max   = sys.fn_cdc_get_max_lsn()                  -- newest change CDC has

if last is NULL                              -> first run: take a full copy (snapshot)
else if fn_cdc_increment_lsn(last) < min     -> changes were lost (see below): take a full copy again
else if fn_cdc_increment_lsn(last) <= max    -> read the changes after the watermark, up to max
else                                         -> nothing new
```

Changes are read with `cdc.fn_cdc_get_all_changes_<capture_instance>(@from, @to, N'all update old')`. The option `all update old` means that for every update we get **two rows**: the row **before** the change (`B`) and the row **after** the change (`U`).

The CDC position columns `__$start_lsn` and `__$seqval` are saved in Bronze. Rows are added to Bronze in the same order they happened: by `start_lsn`, then `seqval`, then operation.

The new Bronze rows and the new watermark (`last_processed_lsn`) are saved **together, in one transaction**. So if a run fails, the watermark does not move, and the next run simply reads the same changes again. Nothing is skipped and nothing is loaded twice.

How each type of change is handled:

| CDC `__$operation` | Bronze `change_operation` | What Silver does |
|---|---|---|
| 1 = delete | `D` | **Soft delete**: the row is kept and flagged `is_deleted = 1` |
| 2 = insert | `I` | Adds or updates the row |
| 3 = update, before the change | `B` | Ignores it (kept in Bronze only as a record) |
| 4 = update, after the change | `U` | Adds or updates the row |
| Full copy (snapshot) | `S` | Adds or updates the row. Keys that are missing from the snapshot are soft deleted. |

## When CDC has lost changes (re-sync)

CDC does not keep changes forever. A cleanup job deletes changes older than the **retention period** (3 days by default). If the pipeline has not run for longer than that, some changes are gone and the watermark points to something that no longer exists.

Instead of quietly skipping those changes, the pipeline does this:

1. It reads the newest position (`max_lsn`) **first**.
2. It copies the whole source table into Bronze as a full snapshot (`S` rows, with `is_full_snapshot = 1`).
3. It saves `max_lsn` as the new watermark, and writes the reason in `audit.cdc_control.last_resync_reason`.

Changes made while the snapshot was being taken are read again by the next run. This is safe, because Silver ignores a change if the values are the same. Silver also soft deletes any key that is missing from the snapshot, so deletes that happened during the gap are not lost.

You can force a full re-sync yourself with:

```sql
EXEC etl.usp_run_pipeline @force_cdc_resync = 1;
```

## What happens when a customer is deleted

When a row is deleted from `source.crm_cust_info`, this is what happens in each layer:

1. **Bronze** saves a `D` row with all the column values and its LSN, so there is a record of the delete.
2. **Silver** sets `is_deleted = 1`. The row is not removed.
3. **Gold** closes the customer's current version in `dim_customers` (sets `expiry_date`, `is_current = 0` and `is_deleted = 1`). Older versions, and the sales that point to them, are not changed.
4. **Reports** still show the customer's last known details, so past revenue is not lost.

## Try it yourself

```sql
-- Change a customer and run the pipeline
UPDATE source.crm_cust_info SET cst_marital_status = 'S' WHERE cst_id = 11000;
EXEC etl.usp_run_pipeline @run_file_ingestion = 0;

-- Bronze now shows: S (first full copy) ... then B (before) and U (after)
SELECT change_operation, cst_marital_status, CONVERT(VARCHAR(22), cdc_start_lsn, 1) AS lsn
FROM bronze.crm_cust_info WHERE cst_id = 11000 ORDER BY bronze_id;

-- Gold now has 2 versions of this customer
SELECT customer_key, marital_status, effective_date, expiry_date, is_current
FROM gold.dim_customers WHERE customer_id = 11000 ORDER BY effective_date;
```

The same check runs automatically in `tests/cdc/test_cdc_capture.sql`.
