/*
===============================================================================
Sales Performance
===============================================================================
In short:
    Tracks sales growth month over month and year over year, the average order
    value, and revenue by country and category.

Purpose:
    - Monthly revenue with month-over-month growth
    - Year-over-year growth (same month, previous year)
    - Average order value per month
    - Revenue by country
    - Sales contribution by category per year

Views Used:
    gold.vw_fact_sales, gold.vw_dim_customers, gold.vw_dim_products
===============================================================================
*/

USE DataWarehouse;
GO

-- =============================================================================
-- 1 + 2 + 3. Monthly revenue, MoM growth, YoY growth, average order value
-- =============================================================================
WITH monthly AS (
    SELECT
        DATEFROMPARTS(YEAR(order_date), MONTH(order_date), 1) AS order_month,
        SUM(sales_amount)              AS revenue,
        COUNT(DISTINCT order_number)   AS orders
    FROM gold.vw_fact_sales
    WHERE order_date IS NOT NULL
    GROUP BY DATEFROMPARTS(YEAR(order_date), MONTH(order_date), 1)
)
SELECT
    order_month,
    revenue,
    orders,
    revenue / NULLIF(orders, 0)                                              AS average_order_value,
    LAG(revenue, 1)  OVER (ORDER BY order_month)                             AS previous_month_revenue,
    CAST((revenue - LAG(revenue, 1) OVER (ORDER BY order_month)) * 100.0
         / NULLIF(LAG(revenue, 1) OVER (ORDER BY order_month), 0) AS DECIMAL(9, 2))  AS mom_growth_pct,
    LAG(revenue, 12) OVER (ORDER BY order_month)                             AS same_month_last_year,
    CAST((revenue - LAG(revenue, 12) OVER (ORDER BY order_month)) * 100.0
         / NULLIF(LAG(revenue, 12) OVER (ORDER BY order_month), 0) AS DECIMAL(9, 2)) AS yoy_growth_pct
FROM monthly
ORDER BY order_month;

-- =============================================================================
-- Yearly revenue and growth
-- =============================================================================
WITH yearly AS (
    SELECT YEAR(order_date) AS order_year, SUM(sales_amount) AS revenue, COUNT(DISTINCT order_number) AS orders
    FROM gold.vw_fact_sales
    WHERE order_date IS NOT NULL
    GROUP BY YEAR(order_date)
)
SELECT
    order_year,
    revenue,
    orders,
    revenue / NULLIF(orders, 0) AS average_order_value,
    CAST((revenue - LAG(revenue) OVER (ORDER BY order_year)) * 100.0
         / NULLIF(LAG(revenue) OVER (ORDER BY order_year), 0) AS DECIMAL(9, 2)) AS yoy_growth_pct
FROM yearly
ORDER BY order_year;

-- =============================================================================
-- 4. Revenue by country
-- =============================================================================
SELECT
    c.country,
    SUM(f.sales_amount)              AS revenue,
    COUNT(DISTINCT f.order_number)   AS orders,
    COUNT(DISTINCT f.customer_key)   AS customers,
    CAST(SUM(f.sales_amount) * 100.0 / SUM(SUM(f.sales_amount)) OVER () AS DECIMAL(5, 2)) AS pct_of_revenue
FROM gold.vw_fact_sales AS f
JOIN gold.vw_dim_customers AS c ON c.customer_key = f.customer_key
GROUP BY c.country
ORDER BY revenue DESC;

-- =============================================================================
-- 5. Category contribution per year
-- =============================================================================
SELECT
    YEAR(f.order_date) AS order_year,
    p.category,
    SUM(f.sales_amount) AS revenue,
    CAST(SUM(f.sales_amount) * 100.0
         / SUM(SUM(f.sales_amount)) OVER (PARTITION BY YEAR(f.order_date)) AS DECIMAL(5, 2)) AS pct_of_year
FROM gold.vw_fact_sales AS f
JOIN gold.vw_dim_products AS p ON p.product_key = f.product_key
WHERE f.order_date IS NOT NULL
GROUP BY YEAR(f.order_date), p.category
ORDER BY order_year, revenue DESC;
GO
