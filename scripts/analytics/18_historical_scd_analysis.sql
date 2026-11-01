/*
===============================================================================
Historical (SCD Type 2) Analysis: "as it was" vs "as it is"
===============================================================================
In short:
    Shows why customer history matters. It compares sales grouped by where
    customers lived at the time of each order with sales grouped by where they
    live today.

Purpose:
    Shows why the customer dimension keeps history.

    - As-was : each sale uses the customer version valid on the order date
               (gold.vw_fact_sales_history joined to gold.dim_customers)
    - As-is  : each sale uses the customer's current attributes
               (gold.vw_fact_sales joined to gold.vw_dim_customers)

    After a customer moves country (a Type 2 change), their past revenue stays
    with the old country in the as-was view and moves in the as-is view.
===============================================================================
*/

USE DataWarehouse;
GO

-- =============================================================================
-- 1. Revenue by country: as-was vs as-is
-- =============================================================================
WITH as_was AS (
    SELECT c.country, SUM(f.sales_amount) AS revenue
    FROM gold.vw_fact_sales_history AS f
    JOIN gold.dim_customers AS c ON c.customer_key = f.customer_key
    GROUP BY c.country
),
as_is AS (
    SELECT c.country, SUM(f.sales_amount) AS revenue
    FROM gold.vw_fact_sales AS f
    JOIN gold.vw_dim_customers AS c ON c.customer_key = f.customer_key
    GROUP BY c.country
)
SELECT
    COALESCE(w.country, i.country)        AS country,
    w.revenue                             AS revenue_as_was,
    i.revenue                             AS revenue_as_is,
    ISNULL(i.revenue, 0) - ISNULL(w.revenue, 0) AS difference
FROM as_was AS w
FULL JOIN as_is AS i ON i.country = w.country
ORDER BY revenue_as_is DESC;

-- =============================================================================
-- 2. Customers with more than one version (their full history)
-- =============================================================================
SELECT
    d.customer_id,
    d.customer_number,
    d.customer_key,
    d.country,
    d.marital_status,
    d.effective_date,
    d.expiry_date,
    d.is_current,
    d.is_deleted
FROM gold.dim_customers AS d
WHERE d.customer_id IN (SELECT customer_id FROM gold.dim_customers GROUP BY customer_id HAVING COUNT(*) > 1)
ORDER BY d.customer_id, d.effective_date;
GO
