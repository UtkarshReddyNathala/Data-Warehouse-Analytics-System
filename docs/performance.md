# Performance

The rule in this project is simple: **speed up real queries, and only report numbers that were actually measured.**

## Indexes

An **index** helps SQL Server find rows quickly, like the index at the back of a book.

| Index | What it speeds up |
|---|---|
| Bronze `(business key, bronze_id)` | Finding the latest change for each key in Silver (`ROW_NUMBER ... ORDER BY bronze_id DESC`) |
| Bronze `(batch_id)` | Tracing data back to its run, tests and monitoring |
| ERP source `(row_version)` | Reading only new rows in incremental loads |
| `silver.crm_sales_details (dwh_row_version)` | Loading only new sales into Gold |
| `silver.crm_cust_info (cst_key)` | Joining the ERP customer data |
| `gold.dim_customers (customer_id, effective_date) INCLUDE (expiry_date, is_current)` | Finding the customer version that was valid on a sale's order date |
| `gold.dim_customers UNIQUE (customer_id) WHERE is_current = 1` | Making sure there is only one current version, and finding it fast |
| `gold.fact_sales (customer_key)`, `(product_key)`, `(order_date_key)` with INCLUDEs | Joining sales to customers, products and dates, and filtering by date |
| `gold.fact_sales UNIQUE (order_number, product_number)` | Matching rows in `MERGE`, and stopping duplicate sales |

**Other things that keep loading fast**

- Every stage only reads the rows that changed.
- Rows are compared by hash, so rows that did not change are never updated. This means fewer writes and no unnecessary CDC records.
- Tables loaded with FULL are copied only when their checksum changes.

**Not used:** table partitioning. About 60,000 sales rows is too small to need it.

**Optional:** a non-clustered columnstore index on `gold.fact_sales` is included as an experiment you can try, in `scripts/performance/optimize_indexes.sql`.

## How to measure speed

`etl.usp_measure_query` runs a query 3 times. It saves the fastest run's elapsed time, CPU time and logical reads (taken from `sys.dm_exec_query_stats`) in `audit.perf_measurement`.

Steps:

1. Run section A of `tests/performance/measure_query_performance.sql` (BEFORE).
2. Make one change, for example add the columnstore index.
3. Run section B (AFTER).
4. Section C shows the comparison.

To see how SQL Server runs a query, run it in SSMS with **Include Actual Execution Plan** turned on, and with `SET STATISTICS IO, TIME ON;`.

## Results

| Query | Before: elapsed / CPU / reads | After: elapsed / CPU / reads | Change |
|---|---|---|---|
| Q1 Monthly revenue | *to be measured* | | |
| Q2 Revenue by country | *to be measured* | | |
| Q3 Revenue by category and year | *to be measured* | | |

Fill in this table from `audit.perf_measurement` after running the measurement script on your own machine. Only write numbers here that you have actually measured.
