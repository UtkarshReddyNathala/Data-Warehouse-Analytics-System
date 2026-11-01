/*
===============================================================================
DDL Script: Data Quality Framework (rules + results)
===============================================================================
In short:
    Creates the data quality rules and the table that stores their results.
    There are 35 rules, such as "no missing customer IDs" or "every sale has a
    valid product".

Script Purpose:
    audit.dq_rule    Declarative data quality rules. Two kinds:
                     CONDITION - "failure_condition" is a WHERE-style predicate
                                 that is TRUE for a failing row.
                     QUERY     - "custom_failed_sql" is a query that returns one
                                 row per failure.
                     Severity CRITICAL stops the pipeline (Silver rules stop the
                     Gold load); WARNING is recorded only.
                     threshold_pct allows a small tolerated failure rate.

    audit.dq_result  One row per rule per batch: records checked, records
                     failed, failure percentage and status.

    The rules are (re)seeded by this script. Existing rules are updated with
    the definitions below; their is_active flag is kept.

Categories: COMPLETENESS, UNIQUENESS, VALIDITY, CONSISTENCY, ACCURACY,
            REFERENTIAL_INTEGRITY, HISTORICAL_INTEGRITY
===============================================================================
*/

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

USE DataWarehouse;
GO

IF OBJECT_ID(N'audit.dq_rule', N'U') IS NULL
BEGIN
    CREATE TABLE audit.dq_rule (
        rule_id            INT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_dq_rule PRIMARY KEY,
        rule_name          NVARCHAR(200)  NOT NULL CONSTRAINT UQ_dq_rule_name UNIQUE,
        layer              NVARCHAR(10)   NOT NULL,
        table_name         NVARCHAR(256)  NOT NULL,
        category           NVARCHAR(30)   NOT NULL,
        severity           NVARCHAR(10)   NOT NULL,
        rule_type          NVARCHAR(10)   NOT NULL,
        failure_condition  NVARCHAR(2000) NULL,
        custom_failed_sql  NVARCHAR(MAX)  NULL,
        row_filter         NVARCHAR(1000) NULL,
        threshold_pct      DECIMAL(9, 4)  NOT NULL CONSTRAINT DF_dq_rule_threshold DEFAULT 0,
        description        NVARCHAR(1000) NULL,
        is_active          BIT            NOT NULL CONSTRAINT DF_dq_rule_active DEFAULT 1,
        CONSTRAINT CK_dq_rule_layer    CHECK (layer IN (N'SILVER', N'GOLD')),
        CONSTRAINT CK_dq_rule_severity CHECK (severity IN (N'CRITICAL', N'WARNING')),
        CONSTRAINT CK_dq_rule_type     CHECK (rule_type IN (N'CONDITION', N'QUERY')),
        CONSTRAINT CK_dq_rule_category CHECK (category IN (N'COMPLETENESS', N'UNIQUENESS', N'VALIDITY', N'CONSISTENCY',
                                                         N'ACCURACY', N'REFERENTIAL_INTEGRITY', N'HISTORICAL_INTEGRITY')),
        CONSTRAINT CK_dq_rule_definition CHECK (
            (rule_type = N'CONDITION' AND failure_condition IS NOT NULL) OR
            (rule_type = N'QUERY' AND custom_failed_sql IS NOT NULL))
    );
END;
GO

IF OBJECT_ID(N'audit.dq_result', N'U') IS NULL
BEGIN
    CREATE TABLE audit.dq_result (
        result_id            BIGINT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_dq_result PRIMARY KEY,
        batch_id             INT            NULL,
        rule_id              INT            NOT NULL,
        rule_name            NVARCHAR(200)  NOT NULL,
        layer                NVARCHAR(10)   NOT NULL,
        table_name           NVARCHAR(256)  NOT NULL,
        category             NVARCHAR(30)   NOT NULL,
        severity             NVARCHAR(10)   NOT NULL,
        records_checked      BIGINT         NULL,
        records_failed       BIGINT         NULL,
        failed_pct           DECIMAL(9, 4)  NULL,
        status               NVARCHAR(10)   NOT NULL,     -- PASSED / WARNING / FAILED / ERROR
        execution_timestamp  DATETIME2(3)   NOT NULL CONSTRAINT DF_dq_result_time DEFAULT SYSDATETIME(),
        error_message        NVARCHAR(4000) NULL
    );
    CREATE INDEX IX_dq_result_batch ON audit.dq_result (batch_id, layer, status);
END;
GO

-- =============================================================================
-- Rule catalogue
-- =============================================================================
MERGE audit.dq_rule AS t
USING (VALUES
-- ---------------------------------------------------------------------------- SILVER
(N'silver.crm_cust_info: customer key present', N'SILVER', N'silver.crm_cust_info', N'COMPLETENESS', N'CRITICAL', N'CONDITION',
    N'cst_key IS NULL OR cst_key = N''''', NULL, N'is_deleted = 0', 0,
    N'Every active customer must have a customer number.'),
(N'silver.crm_cust_info: customer key unique', N'SILVER', N'silver.crm_cust_info', N'UNIQUENESS', N'CRITICAL', N'QUERY',
    NULL, N'SELECT cst_key FROM silver.crm_cust_info WHERE is_deleted = 0 GROUP BY cst_key HAVING COUNT(*) > 1', N'is_deleted = 0', 0,
    N'A customer number may belong to one active customer only.'),
(N'silver.crm_cust_info: names trimmed', N'SILVER', N'silver.crm_cust_info', N'CONSISTENCY', N'WARNING', N'CONDITION',
    N'cst_firstname <> TRIM(cst_firstname) OR cst_lastname <> TRIM(cst_lastname)', NULL, N'is_deleted = 0', 0,
    N'First and last names have no leading or trailing spaces.'),
(N'silver.crm_cust_info: marital status values', N'SILVER', N'silver.crm_cust_info', N'CONSISTENCY', N'CRITICAL', N'CONDITION',
    N'cst_marital_status NOT IN (N''Single'', N''Married'', N''n/a'')', NULL, NULL, 0,
    N'Marital status is standardised.'),
(N'silver.crm_cust_info: gender values', N'SILVER', N'silver.crm_cust_info', N'CONSISTENCY', N'CRITICAL', N'CONDITION',
    N'cst_gndr NOT IN (N''Male'', N''Female'', N''n/a'')', NULL, NULL, 0,
    N'Gender is standardised.'),
(N'silver.crm_prd_info: cost not negative', N'SILVER', N'silver.crm_prd_info', N'VALIDITY', N'CRITICAL', N'CONDITION',
    N'prd_cost < 0', NULL, N'is_deleted = 0', 0,
    N'Product cost cannot be negative.'),
(N'silver.crm_prd_info: end date not before start date', N'SILVER', N'silver.crm_prd_info', N'VALIDITY', N'CRITICAL', N'CONDITION',
    N'prd_end_dt < prd_start_dt', NULL, N'is_deleted = 0', 0,
    N'A product version cannot end before it starts.'),
(N'silver.crm_prd_info: product line values', N'SILVER', N'silver.crm_prd_info', N'CONSISTENCY', N'CRITICAL', N'CONDITION',
    N'prd_line NOT IN (N''Mountain'', N''Road'', N''Other Sales'', N''Touring'', N''n/a'')', NULL, NULL, 0,
    N'Product line codes are translated to names.'),
(N'silver.crm_prd_info: one open version per product', N'SILVER', N'silver.crm_prd_info', N'UNIQUENESS', N'CRITICAL', N'QUERY',
    NULL, N'SELECT prd_key FROM silver.crm_prd_info WHERE is_deleted = 0 AND prd_end_dt IS NULL GROUP BY prd_key HAVING COUNT(*) > 1', N'is_deleted = 0', 0,
    N'Each product number has exactly one version without an end date.'),
(N'silver.crm_sales_details: order date present', N'SILVER', N'silver.crm_sales_details', N'COMPLETENESS', N'WARNING', N'CONDITION',
    N'sls_order_dt IS NULL', NULL, N'is_deleted = 0', 0,
    N'Order dates that were 0 or malformed in the source are NULL. Reported, not rejected.'),
(N'silver.crm_sales_details: order date before ship and due date', N'SILVER', N'silver.crm_sales_details', N'VALIDITY', N'WARNING', N'CONDITION',
    N'sls_order_dt > sls_ship_dt OR sls_order_dt > sls_due_dt', NULL, N'is_deleted = 0', 0,
    N'An order cannot ship or fall due before it is placed.'),
(N'silver.crm_sales_details: sales equals quantity x price', N'SILVER', N'silver.crm_sales_details', N'ACCURACY', N'CRITICAL', N'CONDITION',
    N'ABS(sls_sales - sls_quantity * sls_price) >= sls_quantity', NULL, N'is_deleted = 0', 0,
    N'Sales amount matches quantity x price. A difference smaller than the quantity is allowed because a derived price is a whole number.'),
(N'silver.crm_sales_details: positive amounts', N'SILVER', N'silver.crm_sales_details', N'VALIDITY', N'CRITICAL', N'CONDITION',
    N'sls_quantity <= 0 OR sls_price <= 0 OR sls_sales <= 0', NULL, N'is_deleted = 0', 0,
    N'Quantity, price and sales are positive.'),
(N'silver.crm_sales_details: customer exists', N'SILVER', N'silver.crm_sales_details', N'REFERENTIAL_INTEGRITY', N'WARNING', N'QUERY',
    NULL, N'SELECT s.sls_cust_id FROM silver.crm_sales_details AS s WHERE s.is_deleted = 0 AND NOT EXISTS (SELECT 1 FROM silver.crm_cust_info AS c WHERE c.cst_id = s.sls_cust_id AND c.is_deleted = 0)', N'is_deleted = 0', 0,
    N'Sales whose customer has not arrived yet (late-arriving dimension). Gold maps them to Unknown and fixes them later.'),
(N'silver.crm_sales_details: product exists', N'SILVER', N'silver.crm_sales_details', N'REFERENTIAL_INTEGRITY', N'WARNING', N'QUERY',
    NULL, N'SELECT s.sls_prd_key FROM silver.crm_sales_details AS s WHERE s.is_deleted = 0 AND NOT EXISTS (SELECT 1 FROM silver.crm_prd_info AS p WHERE p.prd_key = s.sls_prd_key AND p.is_deleted = 0)', N'is_deleted = 0', 0,
    N'Sales whose product has not arrived yet.'),
(N'silver.erp_cust_az12: birthdate in range', N'SILVER', N'silver.erp_cust_az12', N'VALIDITY', N'WARNING', N'CONDITION',
    N'bdate < ''1924-01-01'' OR bdate > CAST(SYSDATETIME() AS DATE)', NULL, N'is_deleted = 0', 0,
    N'Very old birthdates are suspicious (future dates are already removed).'),
(N'silver.erp_cust_az12: gender values', N'SILVER', N'silver.erp_cust_az12', N'CONSISTENCY', N'CRITICAL', N'CONDITION',
    N'gen NOT IN (N''Male'', N''Female'', N''n/a'')', NULL, NULL, 0,
    N'Gender is standardised.'),
(N'silver.erp_loc_a101: standard country names', N'SILVER', N'silver.erp_loc_a101', N'CONSISTENCY', N'CRITICAL', N'CONDITION',
    N'cntry IN (N''US'', N''USA'', N''DE'', N''UK'', N''GB'', N'''') OR cntry <> TRIM(cntry)', NULL, NULL, 0,
    N'Country codes are translated to full country names.'),
(N'silver.erp_px_cat_g1v2: values trimmed', N'SILVER', N'silver.erp_px_cat_g1v2', N'CONSISTENCY', N'WARNING', N'CONDITION',
    N'cat <> TRIM(cat) OR subcat <> TRIM(subcat)', NULL, NULL, 0,
    N'Category names have no extra spaces.'),
(N'silver.erp_px_cat_g1v2: maintenance values', N'SILVER', N'silver.erp_px_cat_g1v2', N'CONSISTENCY', N'CRITICAL', N'CONDITION',
    N'maintenance NOT IN (N''Yes'', N''No'', N''n/a'')', NULL, NULL, 0,
    N'Maintenance flag is Yes / No / n/a.'),
-- ---------------------------------------------------------------------------- GOLD
(N'gold.dim_customers: one current version per customer', N'GOLD', N'gold.dim_customers', N'HISTORICAL_INTEGRITY', N'CRITICAL', N'QUERY',
    NULL, N'SELECT customer_id FROM gold.dim_customers WHERE is_current = 1 GROUP BY customer_id HAVING COUNT(*) > 1', NULL, 0,
    N'Only one current version per business key.'),
(N'gold.dim_customers: no overlapping versions', N'GOLD', N'gold.dim_customers', N'HISTORICAL_INTEGRITY', N'CRITICAL', N'QUERY',
    NULL, N'SELECT a.customer_key FROM gold.dim_customers AS a JOIN gold.dim_customers AS b ON a.customer_id = b.customer_id AND a.customer_key < b.customer_key AND a.effective_date < ISNULL(b.expiry_date, ''9999-12-31'') AND b.effective_date < ISNULL(a.expiry_date, ''9999-12-31'')', NULL, 0,
    N'Validity periods of the versions of a customer never overlap.'),
(N'gold.dim_customers: expiry after effective date', N'GOLD', N'gold.dim_customers', N'HISTORICAL_INTEGRITY', N'CRITICAL', N'CONDITION',
    N'expiry_date IS NOT NULL AND expiry_date <= effective_date', NULL, NULL, 0,
    N'A version ends after it starts.'),
(N'gold.dim_customers: current flag matches expiry date', N'GOLD', N'gold.dim_customers', N'HISTORICAL_INTEGRITY', N'CRITICAL', N'CONDITION',
    N'(is_current = 0 AND expiry_date IS NULL) OR (is_current = 1 AND expiry_date IS NOT NULL)', NULL, NULL, 0,
    N'Expired versions have an expiry date; the current version has none.'),
(N'gold.dim_customers: surrogate key unique', N'GOLD', N'gold.dim_customers', N'UNIQUENESS', N'CRITICAL', N'QUERY',
    NULL, N'SELECT customer_key FROM gold.dim_customers GROUP BY customer_key HAVING COUNT(*) > 1', NULL, 0,
    N'Surrogate keys are unique.'),
(N'gold.dim_customers: active customers have a current version', N'GOLD', N'gold.dim_customers', N'COMPLETENESS', N'CRITICAL', N'QUERY',
    NULL, N'SELECT c.cst_id FROM silver.crm_cust_info AS c WHERE c.is_deleted = 0 AND NOT EXISTS (SELECT 1 FROM gold.dim_customers AS d WHERE d.customer_id = c.cst_id AND d.is_current = 1)', NULL, 0,
    N'Every active Silver customer is present in the dimension.'),
(N'gold.dim_products: product number unique', N'GOLD', N'gold.dim_products', N'UNIQUENESS', N'CRITICAL', N'QUERY',
    NULL, N'SELECT product_number FROM gold.dim_products GROUP BY product_number HAVING COUNT(*) > 1', NULL, 0,
    N'One row per product number.'),
(N'gold.fact_sales: order line unique', N'GOLD', N'gold.fact_sales', N'UNIQUENESS', N'CRITICAL', N'QUERY',
    NULL, N'SELECT order_number, product_number FROM gold.fact_sales GROUP BY order_number, product_number HAVING COUNT(*) > 1', NULL, 0,
    N'No duplicate fact rows.'),
(N'gold.fact_sales: customer key exists', N'GOLD', N'gold.fact_sales', N'REFERENTIAL_INTEGRITY', N'CRITICAL', N'QUERY',
    NULL, N'SELECT f.sales_key FROM gold.fact_sales AS f LEFT JOIN gold.dim_customers AS c ON c.customer_key = f.customer_key WHERE c.customer_key IS NULL', NULL, 0,
    N'Every fact row points to an existing customer version.'),
(N'gold.fact_sales: product key exists', N'GOLD', N'gold.fact_sales', N'REFERENTIAL_INTEGRITY', N'CRITICAL', N'QUERY',
    NULL, N'SELECT f.sales_key FROM gold.fact_sales AS f LEFT JOIN gold.dim_products AS p ON p.product_key = f.product_key WHERE p.product_key IS NULL', NULL, 0,
    N'Every fact row points to an existing product.'),
(N'gold.fact_sales: unknown customer rate', N'GOLD', N'gold.fact_sales', N'REFERENTIAL_INTEGRITY', N'WARNING', N'CONDITION',
    N'customer_key = -1', NULL, N'is_deleted = 0', 1.0,
    N'More than 1% of sales without a known customer needs attention.'),
(N'gold.fact_sales: unknown product rate', N'GOLD', N'gold.fact_sales', N'REFERENTIAL_INTEGRITY', N'WARNING', N'CONDITION',
    N'product_key = -1', NULL, N'is_deleted = 0', 1.0,
    N'More than 1% of sales without a known product needs attention.'),
(N'gold.fact_sales: sales equals quantity x price', N'GOLD', N'gold.fact_sales', N'ACCURACY', N'CRITICAL', N'CONDITION',
    N'ABS(sales_amount - quantity * price) >= quantity', NULL, N'is_deleted = 0', 0,
    N'Sales amount matches quantity x price.'),
(N'gold.fact_sales: reconciles with Silver', N'GOLD', N'gold.fact_sales', N'COMPLETENESS', N'CRITICAL', N'QUERY',
    NULL, N'SELECT 1 AS difference WHERE (SELECT COUNT_BIG(*) FROM silver.crm_sales_details WHERE is_deleted = 0) <> (SELECT COUNT_BIG(*) FROM gold.fact_sales WHERE is_deleted = 0)', NULL, 0,
    N'Active fact rows = active Silver sales rows.'),
(N'gold.fact_sales: customer version valid on order date', N'GOLD', N'gold.fact_sales', N'HISTORICAL_INTEGRITY', N'WARNING', N'QUERY',
    NULL, N'SELECT f.sales_key FROM gold.fact_sales AS f JOIN gold.dim_customers AS c ON c.customer_key = f.customer_key WHERE f.is_deleted = 0 AND f.customer_key <> -1 AND f.order_date IS NOT NULL AND NOT (c.effective_date <= f.order_date AND (c.expiry_date IS NULL OR c.expiry_date > f.order_date))', N'is_deleted = 0', 0,
    N'Facts point to the customer version that was valid on the order date.')
) AS s (rule_name, layer, table_name, category, severity, rule_type, failure_condition, custom_failed_sql, row_filter, threshold_pct, description)
ON t.rule_name = s.rule_name
WHEN MATCHED THEN
    UPDATE SET t.layer = s.layer, t.table_name = s.table_name, t.category = s.category, t.severity = s.severity,
               t.rule_type = s.rule_type, t.failure_condition = s.failure_condition, t.custom_failed_sql = s.custom_failed_sql,
               t.row_filter = s.row_filter, t.threshold_pct = s.threshold_pct, t.description = s.description
WHEN NOT MATCHED BY TARGET THEN
    INSERT (rule_name, layer, table_name, category, severity, rule_type, failure_condition, custom_failed_sql, row_filter, threshold_pct, description)
    VALUES (s.rule_name, s.layer, s.table_name, s.category, s.severity, s.rule_type, s.failure_condition, s.custom_failed_sql, s.row_filter, s.threshold_pct, s.description);
GO

PRINT 'Data quality framework ready.';
GO
