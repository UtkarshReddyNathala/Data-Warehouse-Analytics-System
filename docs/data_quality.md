# Data Quality

Data quality checks are built into the pipeline. They run automatically on every load, not as separate scripts that someone has to remember to run.

The order of the checks:

```
Rejected while loading files -> Rejected while cleaning in Silver -> Silver quality rules
    -> (stop here if a CRITICAL rule fails) -> Gold -> Gold quality rules
```

## 1. Rejected records (`silver.rejected_records`)

No record is ever thrown away without a trace. Every rejected record is saved with:

- its original values (as JSON),
- the table it came from,
- the batch (run) and the stage,
- the reason it was rejected,
- the time.

**A rejected row never causes a delete.** When a file is loaded, a row in the source table counts as *missing* only if its key does not appear anywhere in the file. This table shows every case:

| What is in the file | What happens to the existing row in the source table |
|---|---|
| The key is there, and all values are valid | The row is added or updated |
| The key is there, but another value is invalid (for example, a bad date) | The file row is rejected. The existing row is **kept as it was** |
| The key is not in the file | The row is deleted (CDC tables) or marked as deleted (ERP tables) |
| A key value is there but cannot be read | The row is rejected (`INVALID_KEY`). **All deletes are paused** for this load, because the row could belong to any record |
| The key column is blank, but other values are there | The row is rejected (`MISSING_KEY`). **All deletes are paused** for this load, because it could be an existing record whose key was lost |
| The whole line is empty | Rejected (`MISSING_KEY`). It is not a real record, so deletes are **not** paused |
| More than `ingestion_max_delete_pct` of the table would be deleted | The whole load is rejected and nothing is changed |

Note: `cust_info.csv` has 4 rows with a blank `cst_id`. Because of this, deletes through the customer **file** are always paused. Customer deletes made directly in the source table (`DELETE FROM source.crm_cust_info ...`) are still picked up by CDC as normal.

**Reasons you will see**

| Stage | Reason | Example from the data |
|---|---|---|
| INGESTION | `MISSING_KEY` | 4 customer rows with an empty `cst_id` |
| INGESTION | `INVALID_KEY: <columns>` | A key that cannot be read, for example `X7` where a number is expected |
| INGESTION | `TYPE_CONVERSION_FAILED: <columns>` | A date that cannot be read |
| INGESTION | `DUPLICATE_KEY_SUPERSEDED` | 6 older copies of the same customer (the newest wins, based on `dedup_order_by = cst_create_date DESC`) |
| SILVER | `MISSING_CUSTOMER_KEY`, `FUTURE_CREATE_DATE` | Customer rules |
| SILVER | `INVALID_PRODUCT_KEY`, `NEGATIVE_PRODUCT_COST`, `MISSING_START_DATE` | Product rules |
| SILVER | `MISSING_CUSTOMER_ID`, `INVALID_QUANTITY`, `SALES_AND_PRICE_UNUSABLE` | Sales rules |
| SILVER | `DUPLICATE_KEY_AFTER_CLEANING` | Two ERP keys that become the same after removing `NAS` or `-` |

## 2. Cleaning rules (Silver)

| Table | What is cleaned |
|---|---|
| Customers | Extra spaces removed from names; empty text becomes NULL; `S`/`M` becomes Single/Married; `F`/`M` becomes Female/Male; key changed to upper case |
| Products | Category ID taken from the start of the product key; product number is the key without that start; empty cost becomes 0; line codes become names; end date = the day before the next version of the product starts |
| Sales | Dates are stored as numbers (YYYYMMDD). A `0`, a wrong length or an impossible date becomes NULL. A negative price is made positive. Sales = quantity × price when the price is known. A missing price is worked out as sales ÷ quantity |
| ERP customers | The `NAS` prefix is removed from keys; birthdates in the future become NULL; different ways of writing gender (`F`, ` M `, `Female`) are made the same |
| ERP locations | `-` is removed from keys; `DE`, `US`, `USA`, `UK` and blanks become full country names or `n/a` |
| Categories | Extra spaces removed; maintenance is Yes or No |

## 3. The rule engine (`audit.dq_rule` → `audit.dq_result`)

Every quality rule is a **row in a table**, so a new rule can be added without changing any code. There are two kinds of rules:

| Rule type | How it is written | How failing rows are counted |
|---|---|---|
| `CONDITION` | A condition that is true for bad rows (`failure_condition`), for example `prd_cost < 0` | `SUM(CASE WHEN <condition> THEN 1 END)` |
| `QUERY` | A query that returns one row for each problem (`custom_failed_sql`) | `COUNT(*) FROM (<query>)` |

Each rule also has a category, a severity, and optionally a percentage of failures that is allowed (`threshold_pct`).

There are **35 rules** in total:

| Category | What it checks (examples) |
|---|---|
| Completeness | The customer key is filled in; the order date is filled in; every active customer has a current version in Gold; sales in Gold match sales in Silver |
| Uniqueness | Each customer key appears once; each product has only one open version; each order line appears once; surrogate keys are unique |
| Validity | Cost is not negative; the end date is not before the start date; the order date is before the ship and due dates; birthdates are in a sensible range |
| Consistency | Marital status, gender, product line, country names and the maintenance flag use standard values |
| Accuracy | Sales = quantity × price (in Silver and in Gold) |
| Referential integrity | Every key in the sales table exists in the customer, product and date tables; less than 1% of sales link to an Unknown customer or product; sales whose customer or product has not arrived yet |
| Historical integrity | One current version per customer; no overlapping versions; valid end dates; every sale points to the customer version valid on its order date |

## 4. Critical and warning rules

| Severity | What happens when it fails |
|---|---|
| CRITICAL | The result is `FAILED`. If it fails in **Silver**, Gold is **not** loaded and the run fails. If it fails in **Gold**, the run fails. This can be switched with the `dq_stop_on_critical` setting. |
| WARNING | The result is `WARNING`. It is saved in `audit.dq_result`, the run carries on, and it ends as `SUCCESS_WITH_WARNINGS`. The number of warnings is saved in `audit.etl_batch.dq_warning_count`. Example: 19 sales in the source have an invalid order date. |

If a rule itself cannot run (because of a SQL error), it is saved as `ERROR` and treated as critical.

## 5. Where to see the results

```sql
-- Quality results of the latest run
SELECT layer, rule_name, severity, status, records_checked, records_failed, failed_pct
FROM audit.dq_result
WHERE batch_id = (SELECT MAX(batch_id) FROM audit.etl_batch)
ORDER BY status, layer;

-- Rejected rows, grouped by reason
SELECT rejection_stage, source_table, rejection_reason, COUNT(*) AS rows_rejected
FROM silver.rejected_records
GROUP BY rejection_stage, source_table, rejection_reason;
```

The original check queries are also kept in `tests/data_quality/`, so you can run them by hand when investigating a problem.
