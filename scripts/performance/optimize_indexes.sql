/*
===============================================================================
Performance: Index Review and Optional Optimisations
===============================================================================
In short:
    Lists the indexes the warehouse already uses and shows SQL Server's
    suggestions for new ones. It also contains optional extra indexes to test,
    one at a time.

Script Purpose:
    Indexes are added only where a real query uses
    them. The core indexes are already created with the tables:

      Table                      Index                                  Used by
      -------------------------  -------------------------------------  ------------------------------------------
      bronze.*                   (business key, bronze_id)              Silver "latest change per key" ROW_NUMBER
      bronze.*                   (batch_id)                             tests, monitoring, lineage queries
      source.erp_*               (row_version)                          incremental watermark range scans
      silver.crm_sales_details   (dwh_row_version)                      Gold incremental fact load
      silver.crm_cust_info       (cst_key)                              dimension build joins with ERP tables
      gold.dim_customers         (customer_id, effective_date) INCLUDE  point-in-time fact lookups
      gold.dim_customers         UNIQUE (customer_id) WHERE is_current  "one current version" + current lookups
      gold.fact_sales            (customer_key), (product_key),         star joins and date filters in analytics
                                 (order_date_key) with INCLUDEs

    This script contains:
      1. A query to list missing-index suggestions from SQL Server (review them,
         never create them blindly).
      2. A query to find unused indexes (candidates for removal).
      3. An OPTIONAL non-clustered columnstore index on gold.fact_sales.
         With ~60,000 rows the benefit is small; measure before keeping it
         (tests/performance/measure_query_performance.sql).
      4. Statistics maintenance.

    Partitioning is NOT used: the data volume does not justify it.
===============================================================================
*/

USE DataWarehouse;
GO

-- =============================================================================
-- 1. Missing index suggestions (since the last SQL Server restart)
-- =============================================================================
SELECT TOP (20)
    OBJECT_SCHEMA_NAME(d.object_id) + N'.' + OBJECT_NAME(d.object_id) AS table_name,
    d.equality_columns, d.inequality_columns, d.included_columns,
    s.user_seeks, s.user_scans, s.avg_user_impact, s.last_user_seek
FROM sys.dm_db_missing_index_details AS d
JOIN sys.dm_db_missing_index_groups AS g ON g.index_handle = d.index_handle
JOIN sys.dm_db_missing_index_group_stats AS s ON s.group_handle = g.index_group_handle
WHERE d.database_id = DB_ID()
ORDER BY s.avg_user_impact * (s.user_seeks + s.user_scans) DESC;

-- =============================================================================
-- 2. Index usage (unused non-clustered indexes are removal candidates)
-- =============================================================================
SELECT
    OBJECT_SCHEMA_NAME(i.object_id) + N'.' + OBJECT_NAME(i.object_id) AS table_name,
    i.name AS index_name, i.type_desc,
    ISNULL(u.user_seeks, 0) AS user_seeks, ISNULL(u.user_scans, 0) AS user_scans,
    ISNULL(u.user_lookups, 0) AS user_lookups, ISNULL(u.user_updates, 0) AS user_updates
FROM sys.indexes AS i
LEFT JOIN sys.dm_db_index_usage_stats AS u
       ON u.object_id = i.object_id AND u.index_id = i.index_id AND u.database_id = DB_ID()
WHERE OBJECTPROPERTY(i.object_id, 'IsUserTable') = 1
  AND OBJECT_SCHEMA_NAME(i.object_id) IN (N'source', N'bronze', N'silver', N'gold')
  AND i.type_desc = N'NONCLUSTERED'
ORDER BY ISNULL(u.user_seeks, 0) + ISNULL(u.user_scans, 0) + ISNULL(u.user_lookups, 0), table_name;

-- =============================================================================
-- 3. OPTIONAL: non-clustered columnstore index for analytical scans
--    Uncomment, then compare measurements BEFORE / AFTER.
-- =============================================================================
/*
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'NCCI_gold_fact_sales')
    CREATE NONCLUSTERED COLUMNSTORE INDEX NCCI_gold_fact_sales
    ON gold.fact_sales (order_date_key, customer_key, product_key, order_date, sales_amount, quantity, price, is_deleted);

-- To remove it again:
-- DROP INDEX NCCI_gold_fact_sales ON gold.fact_sales;
*/

-- =============================================================================
-- 4. Statistics maintenance after large loads
-- =============================================================================
UPDATE STATISTICS silver.crm_sales_details;
UPDATE STATISTICS gold.fact_sales;
UPDATE STATISTICS gold.dim_customers;
GO
