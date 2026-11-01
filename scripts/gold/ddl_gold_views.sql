/*
===============================================================================
DDL Script: Gold Reporting Views
===============================================================================
In short:
    Creates simple views on top of the Gold tables for reporting. Analysts use
    these views to get current customers, active sales, or sales with history.

Script Purpose:
    The physical star schema keeps full history (several versions per customer,
    flagged deleted sales). Reporting usually needs "as-is" numbers, so these
    views give analysts a simple, stable interface:

    gold.vw_dim_customers   One row per customer: the latest version
                            (current attributes). Includes the Unknown member.
    gold.vw_dim_products    All products, including the Unknown member.
    gold.vw_fact_sales      Active (not deleted) sales. customer_key is mapped
                            to the customer's LATEST version so that joins with
                            gold.vw_dim_customers report current attributes.
    gold.vw_fact_sales_history
                            Active sales with the HISTORICAL customer key
                            (attributes as they were on the order date).
    gold.vw_sales_analysis  Denormalised sales + customer + product + date.

    All scripts in scripts/analytics use these views.
===============================================================================
*/

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

USE DataWarehouse;
GO

-- =============================================================================
-- gold.vw_dim_customers  (latest version per customer)
-- =============================================================================
CREATE OR ALTER VIEW gold.vw_dim_customers AS
SELECT
    d.customer_key,
    d.customer_id,
    d.customer_number,
    d.first_name,
    d.last_name,
    d.country,
    d.marital_status,
    d.gender,
    d.birthdate,
    d.create_date,
    d.is_deleted
FROM (
    SELECT c.*,
           rn = ROW_NUMBER() OVER (PARTITION BY c.customer_id ORDER BY c.effective_date DESC, c.customer_key DESC)
    FROM gold.dim_customers AS c
) AS d
WHERE d.rn = 1;
GO

-- =============================================================================
-- gold.vw_dim_products
-- =============================================================================
CREATE OR ALTER VIEW gold.vw_dim_products AS
SELECT
    product_key,
    product_id,
    product_number,
    product_name,
    category_id,
    category,
    subcategory,
    maintenance,
    cost,
    product_line,
    start_date,
    is_active
FROM gold.dim_products;
GO

-- =============================================================================
-- gold.vw_fact_sales  (active sales, customer_key = latest version)
-- =============================================================================
CREATE OR ALTER VIEW gold.vw_fact_sales AS
SELECT
    f.order_number,
    f.product_key,
    ISNULL(latest.customer_key, f.customer_key) AS customer_key,
    f.order_date,
    f.shipping_date,
    f.due_date,
    f.sales_amount,
    f.quantity,
    f.price
FROM gold.fact_sales AS f
JOIN gold.dim_customers AS hist
    ON hist.customer_key = f.customer_key
LEFT JOIN gold.vw_dim_customers AS latest
    ON latest.customer_id = hist.customer_id
   AND hist.customer_key <> -1
WHERE f.is_deleted = 0;
GO

-- =============================================================================
-- gold.vw_fact_sales_history  (active sales, historical customer version)
-- =============================================================================
CREATE OR ALTER VIEW gold.vw_fact_sales_history AS
SELECT
    f.sales_key,
    f.order_number,
    f.product_key,
    f.customer_key,
    f.order_date_key,
    f.order_date,
    f.shipping_date,
    f.due_date,
    f.sales_amount,
    f.quantity,
    f.price
FROM gold.fact_sales AS f
WHERE f.is_deleted = 0;
GO

-- =============================================================================
-- gold.vw_sales_analysis  (denormalised, current customer attributes)
-- =============================================================================
CREATE OR ALTER VIEW gold.vw_sales_analysis AS
SELECT
    f.order_number,
    f.order_date,
    dd.year_number,
    dd.quarter_number,
    dd.month_number,
    dd.year_month,
    f.shipping_date,
    f.due_date,
    f.sales_amount,
    f.quantity,
    f.price,
    c.customer_key,
    c.customer_number,
    c.first_name,
    c.last_name,
    c.country,
    c.gender,
    c.marital_status,
    p.product_key,
    p.product_number,
    p.product_name,
    p.category,
    p.subcategory,
    p.product_line,
    p.cost
FROM gold.vw_fact_sales AS f
LEFT JOIN gold.vw_dim_customers AS c ON c.customer_key = f.customer_key
LEFT JOIN gold.vw_dim_products  AS p ON p.product_key  = f.product_key
LEFT JOIN gold.dim_date         AS dd ON dd.full_date  = f.order_date;
GO

PRINT 'Gold reporting views ready.';
GO
