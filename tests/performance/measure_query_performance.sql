/*
===============================================================================
Performance Measurement: BEFORE / AFTER
===============================================================================
In short:
    Measures a few typical report queries before and after a change, such as a
    new index, and shows the two side by side.

Purpose:
    Measures representative analytical queries with etl.usp_measure_query,
    which stores real numbers (elapsed ms, CPU ms, logical reads) in
    audit.perf_measurement. Only claim improvements that appear here.

How to use:
    1. Run SECTION A  -> measurements with phase BEFORE.
    2. Apply ONE optimisation (for example the columnstore index in
       scripts/performance/optimize_indexes.sql, section 3).
    3. Run SECTION B  -> measurements with phase AFTER.
    4. Run SECTION C  -> side-by-side comparison.

    For execution plans, run a query manually in SSMS with
    "Include Actual Execution Plan" (Ctrl+M) and
        SET STATISTICS IO, TIME ON;
===============================================================================
*/

USE DataWarehouse;
GO

-- =============================================================================
-- SECTION A: BEFORE
-- =============================================================================
EXEC etl.usp_measure_query @query_name = N'Q1 Monthly revenue', @phase = N'BEFORE',
     @sql = N'SELECT YEAR(order_date) AS y, MONTH(order_date) AS m, SUM(sales_amount) AS revenue
              FROM gold.fact_sales WHERE is_deleted = 0 GROUP BY YEAR(order_date), MONTH(order_date)';

EXEC etl.usp_measure_query @query_name = N'Q2 Revenue by country (as-is)', @phase = N'BEFORE',
     @sql = N'SELECT c.country, SUM(f.sales_amount) AS revenue
              FROM gold.vw_fact_sales AS f JOIN gold.vw_dim_customers AS c ON c.customer_key = f.customer_key
              GROUP BY c.country';

EXEC etl.usp_measure_query @query_name = N'Q3 Revenue by category and year', @phase = N'BEFORE',
     @sql = N'SELECT p.category, d.year_number, SUM(f.sales_amount) AS revenue
              FROM gold.fact_sales AS f
              JOIN gold.dim_products AS p ON p.product_key = f.product_key
              JOIN gold.dim_date AS d ON d.date_key = f.order_date_key
              WHERE f.is_deleted = 0
              GROUP BY p.category, d.year_number';
GO

-- =============================================================================
-- SECTION B: AFTER (run after applying the optimisation)
-- =============================================================================
/*
EXEC etl.usp_measure_query @query_name = N'Q1 Monthly revenue', @phase = N'AFTER',
     @sql = N'SELECT YEAR(order_date) AS y, MONTH(order_date) AS m, SUM(sales_amount) AS revenue
              FROM gold.fact_sales WHERE is_deleted = 0 GROUP BY YEAR(order_date), MONTH(order_date)';

EXEC etl.usp_measure_query @query_name = N'Q2 Revenue by country (as-is)', @phase = N'AFTER',
     @sql = N'SELECT c.country, SUM(f.sales_amount) AS revenue
              FROM gold.vw_fact_sales AS f JOIN gold.vw_dim_customers AS c ON c.customer_key = f.customer_key
              GROUP BY c.country';

EXEC etl.usp_measure_query @query_name = N'Q3 Revenue by category and year', @phase = N'AFTER',
     @sql = N'SELECT p.category, d.year_number, SUM(f.sales_amount) AS revenue
              FROM gold.fact_sales AS f
              JOIN gold.dim_products AS p ON p.product_key = f.product_key
              JOIN gold.dim_date AS d ON d.date_key = f.order_date_key
              WHERE f.is_deleted = 0
              GROUP BY p.category, d.year_number';
*/
GO

-- =============================================================================
-- SECTION C: comparison (latest BEFORE vs latest AFTER per query)
-- =============================================================================
WITH latest AS (
    SELECT *, rn = ROW_NUMBER() OVER (PARTITION BY query_name, phase ORDER BY measured_at DESC)
    FROM audit.perf_measurement
)
SELECT
    b.query_name,
    b.elapsed_ms     AS before_elapsed_ms,  a.elapsed_ms    AS after_elapsed_ms,
    b.cpu_ms         AS before_cpu_ms,      a.cpu_ms        AS after_cpu_ms,
    b.logical_reads  AS before_reads,       a.logical_reads AS after_reads,
    CAST((b.logical_reads - a.logical_reads) * 100.0 / NULLIF(b.logical_reads, 0) AS DECIMAL(9, 2)) AS reads_reduction_pct,
    a.notes
FROM latest AS b
LEFT JOIN latest AS a ON a.query_name = b.query_name AND a.phase = N'AFTER' AND a.rn = 1
WHERE b.phase = N'BEFORE' AND b.rn = 1
ORDER BY b.query_name;
GO
