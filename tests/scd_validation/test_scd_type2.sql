/*
===============================================================================
Test: SCD Type 1 and Type 2 in gold.dim_customers
===============================================================================
In short:
    Tests customer history in Gold: a change of country or marital status
    creates a new version, and a name correction updates every version.

Scenarios:
    1. Type 2 change (marital status, captured by CDC):
       - the previous version is expired (expiry date set, not current)
       - a new version with a new surrogate key is inserted
       - only one current version exists
       - existing sales keep pointing to the old version
    2. Type 1 change (first name): no new version, all versions corrected.
    3. The Gold history rules in audit.dq_rule all pass.
    Finally the original values are restored.
===============================================================================
*/

USE DataWarehouse;
GO
SET NOCOUNT ON;

EXEC test.usp_begin_run N'SCD Type 1 / Type 2';

DECLARE @b INT, @n INT, @ok BIT, @txt NVARCHAR(200), @critical INT, @warnings INT;
DECLARE @customer_id INT, @k1 INT, @k2 INT, @facts_k1 INT, @versions INT;
DECLARE @orig_marital NVARCHAR(50), @orig_first NVARCHAR(50), @new_marital NVARCHAR(50);

EXEC test.usp_run_pipeline @batch_id = @b OUTPUT;   -- start from a clean state

-- A customer with exactly one version and some sales
SELECT TOP (1) @customer_id = d.customer_id, @k1 = d.customer_key
FROM gold.dim_customers AS d
WHERE d.is_current = 1 AND d.customer_key <> -1
  AND d.marital_status IN (N'Single', N'Married')
  AND d.first_name IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM gold.dim_customers AS x WHERE x.customer_id = d.customer_id AND x.customer_key <> d.customer_key)
  AND EXISTS (SELECT 1 FROM gold.fact_sales AS f WHERE f.customer_key = d.customer_key)
ORDER BY d.customer_id;

SELECT @orig_marital = cst_marital_status, @orig_first = cst_firstname FROM source.crm_cust_info WHERE cst_id = @customer_id;
SELECT @facts_k1 = COUNT(*) FROM gold.fact_sales WHERE customer_key = @k1;
SET @new_marital = CASE WHEN UPPER(TRIM(@orig_marital)) = N'M' THEN N'S' ELSE N'M' END;

PRINT '  Test customer: ' + CAST(@customer_id AS NVARCHAR(20)) + ', key ' + CAST(@k1 AS NVARCHAR(20));

-- =============================================================================
-- 1. Type 2 change
-- =============================================================================
UPDATE source.crm_cust_info SET cst_marital_status = @new_marital WHERE cst_id = @customer_id;
EXEC test.usp_run_pipeline @batch_id = @b OUTPUT;

SELECT @ok = CASE WHEN is_current = 0 AND expiry_date IS NOT NULL THEN 1 ELSE 0 END
FROM gold.dim_customers WHERE customer_key = @k1;
EXEC test.usp_assert N'1. Previous version expired', @ok;

SELECT @k2 = customer_key FROM gold.dim_customers WHERE customer_id = @customer_id AND is_current = 1;
SET @ok = CASE WHEN @k2 IS NOT NULL AND @k2 <> @k1 THEN 1 ELSE 0 END;
EXEC test.usp_assert N'1. New version inserted with a new surrogate key', @ok;

SELECT @ok = CASE WHEN d2.effective_date = d1.expiry_date THEN 1 ELSE 0 END
FROM gold.dim_customers AS d1 JOIN gold.dim_customers AS d2 ON d2.customer_key = @k2
WHERE d1.customer_key = @k1;
EXEC test.usp_assert N'1. New version starts exactly when the old one ends (no gap, no overlap)', @ok;

SELECT @n = COUNT(*) FROM gold.dim_customers WHERE customer_id = @customer_id AND is_current = 1;
EXEC test.usp_assert_equals N'1. Exactly one current version', 1, @n;

SELECT @n = COUNT(*) FROM gold.fact_sales WHERE customer_key = @k1;
EXEC test.usp_assert_equals N'1. Historical sales still point to the old version', @facts_k1, @n;

-- =============================================================================
-- 2. Type 1 change
-- =============================================================================
SELECT @versions = COUNT(*) FROM gold.dim_customers WHERE customer_id = @customer_id;

UPDATE source.crm_cust_info SET cst_firstname = N'TypeOneTest' WHERE cst_id = @customer_id;
EXEC test.usp_run_pipeline @batch_id = @b OUTPUT;

SELECT @n = COUNT(*) FROM gold.dim_customers WHERE customer_id = @customer_id;
EXEC test.usp_assert_equals N'2. Type 1 change creates no new version', @versions, @n;

SELECT @n = COUNT(*) FROM gold.dim_customers WHERE customer_id = @customer_id AND first_name <> N'TypeOneTest';
EXEC test.usp_assert_equals N'2. Type 1 change corrected every version', 0, @n;

-- =============================================================================
-- 3. Gold history rules
-- =============================================================================
EXEC etl.usp_run_dq_checks @batch_id = @b, @layer = N'GOLD', @critical_failures = @critical OUTPUT, @warnings = @warnings OUTPUT;
EXEC test.usp_assert_equals N'3. All critical Gold rules pass (history, keys, reconciliation)', 0, @critical;

-- =============================================================================
-- Restore the original values (creates one more Type 2 version, by design)
-- =============================================================================
UPDATE source.crm_cust_info SET cst_marital_status = @orig_marital, cst_firstname = @orig_first WHERE cst_id = @customer_id;
EXEC test.usp_run_pipeline @batch_id = @b OUTPUT;

SELECT @n = COUNT(*) FROM gold.dim_customers WHERE customer_id = @customer_id AND first_name = TRIM(@orig_first);
SELECT @versions = COUNT(*) FROM gold.dim_customers WHERE customer_id = @customer_id;
EXEC test.usp_assert_equals N'Restore: original first name back on every version', @versions, @n;

EXEC test.usp_end_run;
GO
