/*
===============================================================================
Customer Retention and Purchasing Behaviour
===============================================================================
In short:
    Looks at how customers come back: repeat versus one-time buyers, how often
    they buy, and how many of each monthly group return later.

Purpose:
    - Repeat vs one-time customers
    - Purchase frequency distribution
    - Monthly cohort retention (customers grouped by their first order month)
    - Customers with declining activity

Views Used:
    gold.vw_fact_sales, gold.vw_dim_customers
===============================================================================
*/

USE DataWarehouse;
GO

-- =============================================================================
-- 1. Repeat vs one-time customers
-- =============================================================================
WITH customer_orders AS (
    SELECT customer_key, COUNT(DISTINCT order_number) AS orders
    FROM gold.vw_fact_sales
    WHERE customer_key <> -1
    GROUP BY customer_key
)
SELECT
    CASE WHEN orders = 1 THEN 'One-time customer' ELSE 'Repeat customer' END AS customer_type,
    COUNT(*)                                                   AS customers,
    CAST(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER () AS DECIMAL(5, 2)) AS pct_of_customers
FROM customer_orders
GROUP BY CASE WHEN orders = 1 THEN 'One-time customer' ELSE 'Repeat customer' END;

-- =============================================================================
-- 2. Purchase frequency distribution
-- =============================================================================
WITH customer_orders AS (
    SELECT customer_key, COUNT(DISTINCT order_number) AS orders
    FROM gold.vw_fact_sales
    WHERE customer_key <> -1
    GROUP BY customer_key
)
SELECT
    CASE WHEN orders >= 5 THEN '5+' ELSE CAST(orders AS VARCHAR(2)) END AS orders_per_customer,
    COUNT(*) AS customers
FROM customer_orders
GROUP BY CASE WHEN orders >= 5 THEN '5+' ELSE CAST(orders AS VARCHAR(2)) END
ORDER BY MIN(orders);

-- =============================================================================
-- 3. Monthly cohort retention
--    Cohort = month of the first order. For each cohort: how many customers
--    ordered again 1, 2, 3, 6 and 12 months later.
-- =============================================================================
WITH first_order AS (
    SELECT customer_key, DATEFROMPARTS(YEAR(MIN(order_date)), MONTH(MIN(order_date)), 1) AS cohort_month
    FROM gold.vw_fact_sales
    WHERE customer_key <> -1 AND order_date IS NOT NULL
    GROUP BY customer_key
),
activity AS (
    SELECT DISTINCT f.customer_key,
           DATEDIFF(MONTH, fo.cohort_month, DATEFROMPARTS(YEAR(f.order_date), MONTH(f.order_date), 1)) AS month_number
    FROM gold.vw_fact_sales AS f
    JOIN first_order AS fo ON fo.customer_key = f.customer_key
    WHERE f.order_date IS NOT NULL
)
SELECT
    fo.cohort_month,
    COUNT(DISTINCT fo.customer_key)                                                   AS cohort_size,
    COUNT(DISTINCT CASE WHEN a.month_number = 1  THEN a.customer_key END)            AS active_month_1,
    COUNT(DISTINCT CASE WHEN a.month_number = 2  THEN a.customer_key END)            AS active_month_2,
    COUNT(DISTINCT CASE WHEN a.month_number = 3  THEN a.customer_key END)            AS active_month_3,
    COUNT(DISTINCT CASE WHEN a.month_number = 6  THEN a.customer_key END)            AS active_month_6,
    COUNT(DISTINCT CASE WHEN a.month_number = 12 THEN a.customer_key END)            AS active_month_12,
    CAST(COUNT(DISTINCT CASE WHEN a.month_number BETWEEN 1 AND 12 THEN a.customer_key END) * 100.0
         / COUNT(DISTINCT fo.customer_key) AS DECIMAL(5, 2))                          AS retained_within_12_months_pct
FROM first_order AS fo
LEFT JOIN activity AS a ON a.customer_key = fo.customer_key
GROUP BY fo.cohort_month
ORDER BY fo.cohort_month;

-- =============================================================================
-- 4. Customers with declining activity
--    Compares the last 6 months of data with the 6 months before that.
-- =============================================================================
DECLARE @last_date DATE = (SELECT MAX(order_date) FROM gold.vw_fact_sales);
DECLARE @recent_start DATE = DATEADD(MONTH, -6, @last_date);
DECLARE @previous_start DATE = DATEADD(MONTH, -12, @last_date);

WITH spend AS (
    SELECT
        f.customer_key,
        SUM(CASE WHEN f.order_date >  @recent_start   THEN f.sales_amount ELSE 0 END) AS recent_6m_sales,
        SUM(CASE WHEN f.order_date >  @previous_start
                  AND f.order_date <= @recent_start   THEN f.sales_amount ELSE 0 END) AS previous_6m_sales
    FROM gold.vw_fact_sales AS f
    WHERE f.customer_key <> -1 AND f.order_date > @previous_start
    GROUP BY f.customer_key
)
SELECT TOP (50)
    c.customer_number,
    c.first_name,
    c.last_name,
    c.country,
    s.previous_6m_sales,
    s.recent_6m_sales,
    s.recent_6m_sales - s.previous_6m_sales AS change_in_sales
FROM spend AS s
JOIN gold.vw_dim_customers AS c ON c.customer_key = s.customer_key
WHERE s.previous_6m_sales > 0
  AND s.recent_6m_sales < s.previous_6m_sales
ORDER BY change_in_sales;
GO
