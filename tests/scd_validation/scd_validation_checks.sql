/*
===============================================================================
SCD Type 2 Validation Checks (gold.dim_customers)
===============================================================================
In short:
    Manual checks for the customer history table. Every query should return no
    rows; any row it returns points to a history problem.

Script Purpose:
    Ad-hoc checks for the SCD Type 2 customer dimension. History lives in
    gold.dim_customers (effective_date / expiry_date / is_current), which is
    where the analytical history belongs. Silver holds the current state only.

    The same checks run automatically after every load as CRITICAL rules in
    audit.dq_rule (layer GOLD, category HISTORICAL_INTEGRITY).

Usage Notes:
    Every query below should return NO rows.
===============================================================================
*/

USE DataWarehouse;
GO

-- 1. Only ONE current version per customer
SELECT customer_id, COUNT(*) AS current_versions
FROM gold.dim_customers
WHERE is_current = 1
GROUP BY customer_id
HAVING COUNT(*) > 1;

-- 2. Expiry date must be later than the effective date
SELECT customer_key, customer_id, effective_date, expiry_date
FROM gold.dim_customers
WHERE expiry_date IS NOT NULL
  AND expiry_date <= effective_date;

-- 3. No overlapping validity periods between versions of the same customer
SELECT a.customer_id,
       a.customer_key AS version_a, a.effective_date AS a_start, a.expiry_date AS a_end,
       b.customer_key AS version_b, b.effective_date AS b_start, b.expiry_date AS b_end
FROM gold.dim_customers AS a
JOIN gold.dim_customers AS b
    ON a.customer_id = b.customer_id
   AND a.customer_key < b.customer_key
WHERE a.effective_date < ISNULL(b.expiry_date, '9999-12-31')
  AND b.effective_date < ISNULL(a.expiry_date, '9999-12-31');

-- 4. Expired versions have an expiry date, current versions do not
SELECT customer_key, customer_id, is_current, expiry_date
FROM gold.dim_customers
WHERE (is_current = 0 AND expiry_date IS NULL)
   OR (is_current = 1 AND expiry_date IS NOT NULL);

-- 5. Surrogate keys are unique
SELECT customer_key, COUNT(*) AS duplicates
FROM gold.dim_customers
GROUP BY customer_key
HAVING COUNT(*) > 1;

-- 6. No gaps: each later version starts when the previous one ends
SELECT customer_id, customer_key, effective_date, previous_expiry
FROM (
    SELECT customer_id, customer_key, effective_date,
           LAG(expiry_date) OVER (PARTITION BY customer_id ORDER BY effective_date) AS previous_expiry,
           LAG(is_deleted)  OVER (PARTITION BY customer_id ORDER BY effective_date) AS previous_deleted
    FROM gold.dim_customers
) AS v
WHERE previous_expiry IS NOT NULL
  AND previous_deleted = 0              -- a re-activated customer may have a gap after a delete
  AND effective_date <> previous_expiry;

-- 7. Facts point to the version valid on the order date
SELECT TOP (100) f.sales_key, f.order_date, c.customer_key, c.effective_date, c.expiry_date
FROM gold.fact_sales AS f
JOIN gold.dim_customers AS c ON c.customer_key = f.customer_key
WHERE f.customer_key <> -1
  AND f.order_date IS NOT NULL
  AND NOT (c.effective_date <= f.order_date AND (c.expiry_date IS NULL OR c.expiry_date > f.order_date));
GO
