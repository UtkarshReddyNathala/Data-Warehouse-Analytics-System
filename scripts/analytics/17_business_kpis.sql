/*
===============================================================================
Business KPI Views
===============================================================================
In short:
    Creates two views with the main business KPIs, such as total revenue,
    average order value, repeat customer rate and revenue growth.

Purpose:
    Creates reusable KPI views on top of the Gold reporting views.

    gold.vw_kpi_by_year   Per year: total revenue, total orders, average order
                          value, customers, repeat customer rate, revenue growth
    gold.vw_kpi_summary   One row: the same KPIs for the whole data set plus the
                          revenue share of the top 10 products

KPI definitions
    Total Revenue         SUM(sales_amount) of active sales
    Total Orders          number of distinct order numbers
    Average Order Value   Total Revenue / Total Orders
    Repeat Customer Rate  customers with 2+ orders / customers with 1+ orders
    Revenue Growth        (revenue - previous year revenue) / previous year revenue
    Product Contribution  revenue share of the 10 best-selling products
===============================================================================
*/

USE DataWarehouse;
GO

CREATE OR ALTER VIEW gold.vw_kpi_by_year AS
WITH customer_year AS (
    SELECT YEAR(order_date) AS order_year, customer_key, COUNT(DISTINCT order_number) AS orders
    FROM gold.vw_fact_sales
    WHERE order_date IS NOT NULL AND customer_key <> -1
    GROUP BY YEAR(order_date), customer_key
),
repeat_rate AS (
    SELECT order_year,
           COUNT(*)                                   AS customers,
           SUM(CASE WHEN orders >= 2 THEN 1 ELSE 0 END) AS repeat_customers
    FROM customer_year
    GROUP BY order_year
),
yearly AS (
    SELECT YEAR(order_date)              AS order_year,
           SUM(CAST(sales_amount AS BIGINT)) AS total_revenue,
           COUNT(DISTINCT order_number)  AS total_orders
    FROM gold.vw_fact_sales
    WHERE order_date IS NOT NULL
    GROUP BY YEAR(order_date)
)
SELECT
    y.order_year,
    y.total_revenue,
    y.total_orders,
    CAST(y.total_revenue * 1.0 / NULLIF(y.total_orders, 0) AS DECIMAL(12, 2))                     AS average_order_value,
    r.customers,
    CAST(r.repeat_customers * 100.0 / NULLIF(r.customers, 0) AS DECIMAL(5, 2))                     AS repeat_customer_rate_pct,
    CAST((y.total_revenue - LAG(y.total_revenue) OVER (ORDER BY y.order_year)) * 100.0
         / NULLIF(LAG(y.total_revenue) OVER (ORDER BY y.order_year), 0) AS DECIMAL(9, 2))           AS revenue_growth_pct
FROM yearly AS y
LEFT JOIN repeat_rate AS r ON r.order_year = y.order_year;
GO

CREATE OR ALTER VIEW gold.vw_kpi_summary AS
WITH totals AS (
    SELECT SUM(CAST(sales_amount AS BIGINT)) AS total_revenue,
           COUNT(DISTINCT order_number)      AS total_orders
    FROM gold.vw_fact_sales
),
customers AS (
    SELECT COUNT(*) AS customers, SUM(CASE WHEN orders >= 2 THEN 1 ELSE 0 END) AS repeat_customers
    FROM (SELECT customer_key, COUNT(DISTINCT order_number) AS orders
          FROM gold.vw_fact_sales WHERE customer_key <> -1 GROUP BY customer_key) AS x
),
top_products AS (
    SELECT SUM(revenue) AS top10_revenue
    FROM (SELECT TOP (10) product_key, SUM(CAST(sales_amount AS BIGINT)) AS revenue
          FROM gold.vw_fact_sales GROUP BY product_key ORDER BY revenue DESC) AS t
)
SELECT
    t.total_revenue,
    t.total_orders,
    CAST(t.total_revenue * 1.0 / NULLIF(t.total_orders, 0) AS DECIMAL(12, 2))       AS average_order_value,
    c.customers,
    CAST(c.repeat_customers * 100.0 / NULLIF(c.customers, 0) AS DECIMAL(5, 2))      AS repeat_customer_rate_pct,
    CAST(tp.top10_revenue * 100.0 / NULLIF(t.total_revenue, 0) AS DECIMAL(5, 2))    AS top10_product_contribution_pct
FROM totals AS t
CROSS JOIN customers AS c
CROSS JOIN top_products AS tp;
GO

-- Example usage
SELECT * FROM gold.vw_kpi_summary;
SELECT * FROM gold.vw_kpi_by_year ORDER BY order_year;
GO
