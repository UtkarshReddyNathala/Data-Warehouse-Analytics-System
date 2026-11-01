# Metadata-Driven ETL

**Metadata-driven** means the pipeline reads how to load each table from a table, `audit.etl_config`, instead of having a hard-coded script per table. To change how a table loads, you change a row in this table, not the code.

## One procedure loads everything

`etl.usp_run_metadata_driven_load` is the only procedure that runs the first three stages: **Ingestion** (files), **Bronze** and **Silver**. The main pipeline (`etl.usp_run_pipeline`) calls it once for each stage.

Steps:

```
for each active row in audit.etl_config, in load_priority order:
    INGESTION stage -> run etl.usp_ingest_source_file       (only if source_file_path is set)
    BRONZE stage    -> run bronze.usp_extract_table         (CDC, INCREMENTAL or FULL)
    SILVER stage    -> run the Silver procedure named in the settings
    write one row to audit.etl_step_log (row counts, status, message)
    if there is an error: write it to audit.etl_error_log;
        stop if the table is critical (is_critical = 1), otherwise carry on
```

Each Silver table needs its own cleaning rules (for example country codes, product keys, or sales calculations), so those cannot be fully generic. To handle this, `audit.etl_config` stores the **name** of each table's Silver procedure, and the pipeline calls it by name. All Silver procedures take the same parameters. Everything else is generic: column names, types and keys are read from SQL Server's own system tables.

## The metadata table: `audit.etl_config`

| Column | What it means |
|---|---|
| `source_system` | Which system the data comes from: CRM or ERP |
| `source_schema`, `source_table` | The source table (the simulated company database) |
| `target_schema`, `target_table` | The Bronze table to load into |
| `load_type` | How to load: `FULL` (copy everything), `INCREMENTAL` (only new rows, using a watermark) or `CDC` (use Change Data Capture) |
| `watermark_column` | Only for INCREMENTAL. The watermark column: a ROWVERSION column (recommended) or a date/time column |
| `primary_key_columns` | The column(s) that identify a row, separated by commas |
| `capture_instance` | Only for CDC. The name of the table's CDC change log (a CHECK constraint makes sure it is filled in) |
| `source_file_path` | Where the CSV file is, relative to the `data_root` setting |
| `landing_table` | The table in the `landing` schema where the raw file text is loaded first |
| `file_date_format` | How dates are written in the file: `ymd`, `dmy` or `mdy` (the product file uses `dd-mm-yyyy`) |
| `dedup_order_by` | If a key appears more than once in a file, which row wins. Example: `cst_create_date DESC` (the newest one) |
| `missing_row_action` | What to do with rows that are no longer in the file: `DELETE`, `SOFT_DELETE` (mark as deleted) or `IGNORE` |
| `silver_schema`, `silver_table`, `silver_procedure` | The Silver table and the procedure that cleans the data into it |
| `is_active` | 1 = load this table, 0 = skip it |
| `is_critical` | 1 = if this table fails, the whole pipeline stops |
| `load_priority` | The order in which tables are loaded |

**How each table is set up today**

| Table | Load type | Why |
|---|---|---|
| `crm_cust_info` | CDC | Customer changes and deletes are needed to keep customer history |
| `crm_prd_info` | CDC | Products change over time |
| `crm_sales_details` | CDC | This is the biggest table, so only changed lines should be processed |
| `erp_cust_az12` | INCREMENTAL (`row_version`) | The ERP has no CDC. A ROWVERSION column is a reliable and cheap watermark |
| `erp_loc_a101` | INCREMENTAL (`row_version`) | Same reason. Deletes are made visible by marking rows as deleted (soft delete) |
| `erp_px_cat_g1v2` | FULL | Only 37 rows. A full copy is taken only when the table's checksum changes |

## Checking the configuration before every run

`etl.usp_validate_config` runs at the start of every pipeline run. It stops the run if it finds any of these problems:

- A source, landing, Bronze or Silver table is missing, or a Silver procedure is missing.
- A primary key column does not exist.
- An INCREMENTAL watermark column does not exist, or is not a ROWVERSION or date/time column.
- A CDC table's capture instance does not exist, or CDC is not turned on.
- `SOFT_DELETE` is chosen but the table has no `is_deleted` or `modified_at` column.
- `dedup_order_by` names a column that does not exist, or contains anything other than column names and ASC/DESC.
- The CSV file has a column that the source table does not have.
- A CDC table has no row in `audit.cdc_control`, or that row names a different capture instance.
- A source column is not tracked by CDC (this happens when a column is added after CDC was turned on).
- A source column is missing in Bronze, or has a different type or a shorter length there.
- The primary key is not unique, or contains empty (NULL) values, in the actual source data.
- A Silver procedure does not have the standard parameters: `@batch_id`, and the OUTPUT parameters `@rows_read`, `@rows_inserted`, `@rows_updated`, `@rows_deleted`, `@rows_rejected` and `@message`.

You can run the check yourself and see the results:

```sql
EXEC etl.usp_validate_config @raise_error = 0, @return_results = 1;
```

## Building SQL safely

The pipeline builds **dynamic SQL** (SQL statements created at run time from the metadata), so it follows these safety rules:

- Every table and column name is wrapped in `QUOTENAME()`, and full table names are split with `PARSENAME()`.
- Column lists, data types and key columns are read from `sys.columns`, never typed by hand.
- Values such as the batch ID, LSNs and watermarks are passed as parameters to `sp_executesql`, never pasted into the SQL text.
- The only free-text setting, `dedup_order_by`, is checked against the real columns first.

## Common changes (no code needed)

```sql
-- Stop loading a table
UPDATE audit.etl_config SET is_active = 0 WHERE source_table = N'erp_px_cat_g1v2';

-- Change a table from INCREMENTAL to FULL (each load type keeps its own watermark)
UPDATE audit.etl_config SET load_type = N'FULL', watermark_column = NULL WHERE source_table = N'erp_loc_a101';

-- Let a table fail without stopping the whole pipeline
UPDATE audit.etl_config SET is_critical = 0 WHERE source_table = N'erp_px_cat_g1v2';

-- Check that the configuration is still valid
EXEC etl.usp_validate_config @raise_error = 0, @return_results = 1;
```

## Adding a new source table

To add a seventh table, you need:

1. A landing table and its bulk-load view.
2. A source table.
3. A Bronze table with the standard extra columns.
4. A Silver table and a Silver procedure, following the template in `scripts/silver/proc_load_silver.sql`.
5. One new row in `audit.etl_config`.
