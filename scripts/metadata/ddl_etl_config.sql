/*
===============================================================================
DDL Script: Metadata-Driven ETL Configuration (audit.etl_config)
===============================================================================
In short:
    Creates audit.etl_config, the table that controls how each source table is
    loaded. To switch a table on or off, or change how it loads, you edit this
    table instead of the code.

Script Purpose:
    One row per source table. The metadata-driven loader reads this table to
    decide, for every table:
      - which CSV file feeds the simulated source table (ingestion),
      - how changes are extracted into Bronze (FULL / INCREMENTAL / CDC),
      - which Silver procedure cleans the data,
      - whether the table is active, its execution order and whether a failure
        must stop the whole pipeline.

    Change the loading behaviour by updating this table, not the code:
        UPDATE audit.etl_config SET is_active = 0 WHERE source_table = N'erp_px_cat_g1v2';
        UPDATE audit.etl_config SET load_type = N'FULL', watermark_column = NULL
        WHERE source_table = N'erp_loc_a101';

    Validate any change with:  EXEC etl.usp_validate_config @return_results = 1;
===============================================================================
*/

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

USE DataWarehouse;
GO

IF OBJECT_ID(N'audit.etl_config', N'U') IS NULL
BEGIN
    CREATE TABLE audit.etl_config (
        config_id            INT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_etl_config PRIMARY KEY,
        source_system        NVARCHAR(10)   NOT NULL,
        source_schema        NVARCHAR(128)  NOT NULL CONSTRAINT DF_etl_config_src_schema DEFAULT N'source',
        source_table         NVARCHAR(128)  NOT NULL,
        target_schema        NVARCHAR(128)  NOT NULL CONSTRAINT DF_etl_config_tgt_schema DEFAULT N'bronze',
        target_table         NVARCHAR(128)  NOT NULL,
        load_type            NVARCHAR(20)   NOT NULL,          -- FULL / INCREMENTAL / CDC
        watermark_column     NVARCHAR(128)  NULL,              -- INCREMENTAL only (rowversion or datetime column)
        primary_key_columns  NVARCHAR(400)  NOT NULL,          -- comma separated business key
        capture_instance     NVARCHAR(128)  NULL,              -- CDC only
        source_file_path     NVARCHAR(400)  NULL,              -- relative to the data_root setting
        landing_table        NVARCHAR(128)  NULL,              -- table in the landing schema
        file_date_format     CHAR(3)        NOT NULL CONSTRAINT DF_etl_config_datefmt DEFAULT 'ymd',
        dedup_order_by       NVARCHAR(400)  NULL,              -- which duplicate row wins in a file, e.g. "cst_create_date DESC"
        missing_row_action   NVARCHAR(20)   NOT NULL CONSTRAINT DF_etl_config_missing DEFAULT N'DELETE',
        silver_schema        NVARCHAR(128)  NOT NULL CONSTRAINT DF_etl_config_silver_schema DEFAULT N'silver',
        silver_table         NVARCHAR(128)  NOT NULL,
        silver_procedure     NVARCHAR(128)  NOT NULL,
        is_active            BIT            NOT NULL CONSTRAINT DF_etl_config_active DEFAULT 1,
        is_critical          BIT            NOT NULL CONSTRAINT DF_etl_config_critical DEFAULT 1,
        load_priority        INT            NOT NULL,
        created_at           DATETIME2(3)   NOT NULL CONSTRAINT DF_etl_config_created DEFAULT SYSDATETIME(),
        updated_at           DATETIME2(3)   NOT NULL CONSTRAINT DF_etl_config_updated DEFAULT SYSDATETIME(),

        CONSTRAINT UQ_etl_config_source UNIQUE (source_schema, source_table),
        CONSTRAINT CK_etl_config_system      CHECK (source_system IN (N'CRM', N'ERP')),
        CONSTRAINT CK_etl_config_load_type   CHECK (load_type IN (N'FULL', N'INCREMENTAL', N'CDC')),
        CONSTRAINT CK_etl_config_date_format CHECK (file_date_format IN ('ymd', 'dmy', 'mdy')),
        CONSTRAINT CK_etl_config_missing     CHECK (missing_row_action IN (N'DELETE', N'SOFT_DELETE', N'IGNORE')),
        -- A capture instance is required for CDC and not allowed otherwise
        CONSTRAINT CK_etl_config_cdc CHECK (
            (load_type = N'CDC' AND capture_instance IS NOT NULL) OR
            (load_type <> N'CDC' AND capture_instance IS NULL)
        )
    );
END;
GO

-- =============================================================================
-- Seed configuration (only inserted when missing; your changes are kept)
-- =============================================================================
MERGE audit.etl_config AS t
USING (VALUES
--   system  source_table          target_table          load_type      watermark       primary key                   capture instance             file                        landing table         fmt    dedup                     missing        silver_table          silver procedure                 prio
    (N'CRM', N'crm_cust_info',     N'crm_cust_info',     N'CDC',        NULL,           N'cst_id',                    N'source_crm_cust_info',     N'crm/cust_info.csv',       N'crm_cust_info',     'ymd', N'cst_create_date DESC',  N'DELETE',      N'crm_cust_info',     N'usp_load_crm_cust_info',     10),
    (N'CRM', N'crm_prd_info',      N'crm_prd_info',      N'CDC',        NULL,           N'prd_id',                    N'source_crm_prd_info',      N'crm/prd_info.csv',        N'crm_prd_info',      'dmy', NULL,                     N'DELETE',      N'crm_prd_info',      N'usp_load_crm_prd_info',      20),
    (N'CRM', N'crm_sales_details', N'crm_sales_details', N'CDC',        NULL,           N'sls_ord_num,sls_prd_key',   N'source_crm_sales_details', N'crm/sales_details.csv',   N'crm_sales_details', 'ymd', NULL,                     N'DELETE',      N'crm_sales_details', N'usp_load_crm_sales_details', 30),
    (N'ERP', N'erp_cust_az12',     N'erp_cust_az12',     N'INCREMENTAL',N'row_version', N'cid',                       NULL,                        N'erp/cust_az12.csv',       N'erp_cust_az12',     'ymd', NULL,                     N'SOFT_DELETE', N'erp_cust_az12',     N'usp_load_erp_cust_az12',     40),
    (N'ERP', N'erp_loc_a101',      N'erp_loc_a101',      N'INCREMENTAL',N'row_version', N'cid',                       NULL,                        N'erp/loc_a101.csv',        N'erp_loc_a101',      'ymd', NULL,                     N'SOFT_DELETE', N'erp_loc_a101',      N'usp_load_erp_loc_a101',      50),
    (N'ERP', N'erp_px_cat_g1v2',   N'erp_px_cat_g1v2',   N'FULL',       NULL,           N'id',                        NULL,                        N'erp/px_cat_g1v2.csv',     N'erp_px_cat_g1v2',   'ymd', NULL,                     N'DELETE',      N'erp_px_cat_g1v2',   N'usp_load_erp_px_cat_g1v2',   60)
) AS s (source_system, source_table, target_table, load_type, watermark_column, primary_key_columns, capture_instance,
        source_file_path, landing_table, file_date_format, dedup_order_by, missing_row_action, silver_table, silver_procedure, load_priority)
ON t.source_schema = N'source' AND t.source_table = s.source_table
WHEN NOT MATCHED BY TARGET THEN
    INSERT (source_system, source_schema, source_table, target_schema, target_table, load_type, watermark_column,
            primary_key_columns, capture_instance, source_file_path, landing_table, file_date_format, dedup_order_by,
            missing_row_action, silver_schema, silver_table, silver_procedure, is_active, is_critical, load_priority)
    VALUES (s.source_system, N'source', s.source_table, N'bronze', s.target_table, s.load_type, s.watermark_column,
            s.primary_key_columns, s.capture_instance, s.source_file_path, s.landing_table, s.file_date_format, s.dedup_order_by,
            s.missing_row_action, N'silver', s.silver_table, s.silver_procedure, 1, 1, s.load_priority);
GO

PRINT 'audit.etl_config ready.';
GO
