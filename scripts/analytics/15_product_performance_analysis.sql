/*
===============================================================================
Product Performance
===============================================================================
In short:
    Finds the top products, each category's share of revenue, yearly trends and
    products whose sales are falling.

Purpose:
    - Top products by revenue
    - Revenue by category and its share of the total
    - Yearly product sales trend
    - Products with declining sales (latest full year vs the year before)
    - Product contribution to total revenue (Pareto / cumulative share)

Views Used:
    gold.vw_fact_sales, gold.vw_dim_products
===============================================================================
*/

USE DataWarehouse;
GO

-- =============================================================================
-- 1. Top 10 products by revenue
-- =============================================================================
SELECT TOP (10)
    p.product_name,
    p.category,
    SUM(f.sales_amount)              AS total_revenue,
    SUM(f.quantity)                  AS units_sold,
    COUNT(DISTINCT f.order_number)   AS orders
FROM gold.vw_fact_sales AS f
JOIN gold.vw_dim_products AS p ON p.product_key = f.product_key
GROUP BY p.product_name, p.category
ORDER BY total_revenue DESC;

-- =============================================================================
-- 2. Revenue by category with share of total
-- =============================================================================
SELECT
    p.category,
    SUM(f.sales_amount) AS category_revenue,
    CAST(SUM(f.sales_amount) * 100.0 / SUM(SUM(f.sales_amount)) OVER () AS DECIMAL(5, 2)) AS pct_of_total
FROM gold.vw_fact_sales AS f
JOIN gold.vw_dim_products AS p ON p.product_key = f.product_key
GROUP BY p.category
ORDER BY category_revenue DESC;

-- =============================================================================
-- 3. Yearly sales trend per product (with previous year)
-- =============================================================================
WITH yearly AS (
    SELECT p.product_name, YEAR(f.order_date) AS order_year, SUM(f.sales_amount) AS revenue
    FROM gold.vw_fact_sales AS f
    JOIN gold.vw_dim_products AS p ON p.product_key = f.product_key
    WHERE f.order_date IS NOT NULL
    GROUP BY p.product_name, YEAR(f.order_date)
)
SELECT
    product_name,
    order_year,
    revenue,
    LAG(revenue) OVER (PARTITION BY product_name ORDER BY order_year) AS previous_year_revenue
FROM yearly
ORDER BY product_name, order_year;

-- =============================================================================
-- 4. Products with declining sales (latest full year vs the year before)
-- =============================================================================
DECLARE @latest_full_year INT =
    (SELECT MAX(YEAR(order_date)) FROM gold.vw_fact_sales WHERE MONTH(order_date) = 12);

WITH yearly AS (
    SELECT p.product_name,
           SUM(CASE WHEN YEAR(f.order_date) = @latest_full_year     THEN f.sales_amount ELSE 0 END) AS latest_year,
           SUM(CASE WHEN YEAR(f.order_date) = @latest_full_year - 1 THEN f.sales_amount ELSE 0 END) AS previous_year
    FROM gold.vw_fact_sales AS f
    JOIN gold.vw_dim_products AS p ON p.product_key = f.product_key
    GROUP BY p.product_name
)
SELECT
    product_name,
    previous_year,
    latest_year,
    CAST((latest_year - previous_year) * 100.0 / NULLIF(previous_year, 0) AS DECIMAL(9, 2)) AS change_pct
FROM yearly
WHERE previous_year > 0 AND latest_year < previous_year
ORDER BY change_pct;

-- =============================================================================
-- 5. Product contribution and cumulative share (Pareto)
-- =============================================================================
WITH product_revenue AS (
    SELECT p.product_name, SUM(f.sales_amount) AS revenue
    FROM gold.vw_fact_sales AS f
    JOIN gold.vw_dim_products AS p ON p.product_key = f.product_key
    GROUP BY p.product_name
)
SELECT
    product_name,
    revenue,
    CAST(revenue * 100.0 / SUM(revenue) OVER () AS DECIMAL(6, 3)) AS pct_of_revenue,
    CAST(SUM(revenue) OVER (ORDER BY revenue DESC ROWS UNBOUNDED PRECEDING) * 100.0
         / SUM(revenue) OVER () AS DECIMAL(6, 2))               AS cumulative_pct
FROM product_revenue
ORDER BY revenue DESC;
GO
