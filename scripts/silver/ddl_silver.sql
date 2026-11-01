/*
===============================================================================
DDL Script: Silver Tables (cleaned, standardised, current state)
===============================================================================
In short:
    Creates the Silver tables, which hold one clean, up-to-date row for each
    customer, product and sale. It also creates the table where rejected records
    are kept with the reason they failed.

Script Purpose:
    Silver holds ONE cleaned row per business key (current state). It is
    maintained incrementally from Bronze with MERGE logic instead of being
    truncated and reloaded.

    Metadata columns on every Silver table:
      is_deleted            1 when the record was deleted in the source (soft delete,
                            so Gold can expire the dimension version and keep history)
      dwh_batch_id          batch that last changed the row
      dwh_source_bronze_id  Bronze row that produced the current values (lineage)
      dwh_create_date       first time the row was written
      dwh_update_date       last time the row changed
      dwh_row_hash          SHA2_256 of the cleaned business columns (change detection)
      dwh_row_version       ROWVERSION: the Gold layer's incremental watermark

    silver.rejected_records keeps every record that failed a rule, with the
    original values (JSON), the reason, the stage and the batch.

    History (SCD Type 2) is kept in the Gold dimensions, not in Silver.
===============================================================================
*/

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

USE DataWarehouse;
GO

-- =============================================================================
-- silver.crm_cust_info
-- =============================================================================
IF OBJECT_ID(N'silver.crm_cust_info', N'U') IS NULL
BEGIN
    CREATE TABLE silver.crm_cust_info (
        cst_id                INT            NOT NULL CONSTRAINT PK_silver_crm_cust_info PRIMARY KEY,
        cst_key               NVARCHAR(50)   NOT NULL,
        cst_firstname         NVARCHAR(50)   NULL,
        cst_lastname          NVARCHAR(50)   NULL,
        cst_marital_status    NVARCHAR(50)   NOT NULL,
        cst_gndr              NVARCHAR(50)   NOT NULL,
        cst_create_date       DATE           NULL,
        is_deleted            BIT            NOT NULL CONSTRAINT DF_silver_crm_cust_info_del DEFAULT 0,
        dwh_batch_id          INT            NULL,
        dwh_source_bronze_id  BIGINT         NULL,
        dwh_create_date       DATETIME2(3)   NOT NULL CONSTRAINT DF_silver_crm_cust_info_cre DEFAULT SYSDATETIME(),
        dwh_update_date       DATETIME2(3)   NOT NULL CONSTRAINT DF_silver_crm_cust_info_upd DEFAULT SYSDATETIME(),
        dwh_row_hash          VARBINARY(32)  NOT NULL,
        dwh_row_version       ROWVERSION     NOT NULL
    );
    CREATE INDEX IX_silver_crm_cust_info_key ON silver.crm_cust_info (cst_key);
    CREATE INDEX IX_silver_crm_cust_info_rv  ON silver.crm_cust_info (dwh_row_version);
END;
GO

-- =============================================================================
-- silver.crm_prd_info
-- =============================================================================
IF OBJECT_ID(N'silver.crm_prd_info', N'U') IS NULL
BEGIN
    CREATE TABLE silver.crm_prd_info (
        prd_id                INT            NOT NULL CONSTRAINT PK_silver_crm_prd_info PRIMARY KEY,
        cat_id                NVARCHAR(50)   NOT NULL,
        prd_key               NVARCHAR(50)   NOT NULL,
        prd_nm                NVARCHAR(50)   NULL,
        prd_cost              INT            NOT NULL,
        prd_line              NVARCHAR(50)   NOT NULL,
        prd_start_dt          DATE           NOT NULL,
        prd_end_dt            DATE           NULL,     -- derived: day before the next version starts
        is_deleted            BIT            NOT NULL CONSTRAINT DF_silver_crm_prd_info_del DEFAULT 0,
        dwh_batch_id          INT            NULL,
        dwh_source_bronze_id  BIGINT         NULL,
        dwh_create_date       DATETIME2(3)   NOT NULL CONSTRAINT DF_silver_crm_prd_info_cre DEFAULT SYSDATETIME(),
        dwh_update_date       DATETIME2(3)   NOT NULL CONSTRAINT DF_silver_crm_prd_info_upd DEFAULT SYSDATETIME(),
        dwh_row_hash          VARBINARY(32)  NOT NULL,
        dwh_row_version       ROWVERSION     NOT NULL
    );
    CREATE INDEX IX_silver_crm_prd_info_key ON silver.crm_prd_info (prd_key, prd_start_dt);
END;
GO

-- =============================================================================
-- silver.crm_sales_details
-- =============================================================================
IF OBJECT_ID(N'silver.crm_sales_details', N'U') IS NULL
BEGIN
    CREATE TABLE silver.crm_sales_details (
        sls_ord_num           NVARCHAR(50)   NOT NULL,
        sls_prd_key           NVARCHAR(50)   NOT NULL,
        sls_cust_id           INT            NOT NULL,
        sls_order_dt          DATE           NULL,
        sls_ship_dt           DATE           NULL,
        sls_due_dt            DATE           NULL,
        sls_sales             INT            NOT NULL,
        sls_quantity          INT            NOT NULL,
        sls_price             INT            NOT NULL,
        is_deleted            BIT            NOT NULL CONSTRAINT DF_silver_crm_sales_details_del DEFAULT 0,
        dwh_batch_id          INT            NULL,
        dwh_source_bronze_id  BIGINT         NULL,
        dwh_create_date       DATETIME2(3)   NOT NULL CONSTRAINT DF_silver_crm_sales_details_cre DEFAULT SYSDATETIME(),
        dwh_update_date       DATETIME2(3)   NOT NULL CONSTRAINT DF_silver_crm_sales_details_upd DEFAULT SYSDATETIME(),
        dwh_row_hash          VARBINARY(32)  NOT NULL,
        dwh_row_version       ROWVERSION     NOT NULL,
        CONSTRAINT PK_silver_crm_sales_details PRIMARY KEY (sls_ord_num, sls_prd_key)
    );
    CREATE INDEX IX_silver_crm_sales_details_rv   ON silver.crm_sales_details (dwh_row_version);
    CREATE INDEX IX_silver_crm_sales_details_cust ON silver.crm_sales_details (sls_cust_id);
END;
GO

-- =============================================================================
-- silver.erp_cust_az12
-- =============================================================================
IF OBJECT_ID(N'silver.erp_cust_az12', N'U') IS NULL
BEGIN
    CREATE TABLE silver.erp_cust_az12 (
        cid                   NVARCHAR(50)   NOT NULL CONSTRAINT PK_silver_erp_cust_az12 PRIMARY KEY,
        bdate                 DATE           NULL,
        gen                   NVARCHAR(50)   NOT NULL,
        is_deleted            BIT            NOT NULL CONSTRAINT DF_silver_erp_cust_az12_del DEFAULT 0,
        dwh_batch_id          INT            NULL,
        dwh_source_bronze_id  BIGINT         NULL,
        dwh_create_date       DATETIME2(3)   NOT NULL CONSTRAINT DF_silver_erp_cust_az12_cre DEFAULT SYSDATETIME(),
        dwh_update_date       DATETIME2(3)   NOT NULL CONSTRAINT DF_silver_erp_cust_az12_upd DEFAULT SYSDATETIME(),
        dwh_row_hash          VARBINARY(32)  NOT NULL,
        dwh_row_version       ROWVERSION     NOT NULL
    );
END;
GO

-- =============================================================================
-- silver.erp_loc_a101
-- =============================================================================
IF OBJECT_ID(N'silver.erp_loc_a101', N'U') IS NULL
BEGIN
    CREATE TABLE silver.erp_loc_a101 (
        cid                   NVARCHAR(50)   NOT NULL CONSTRAINT PK_silver_erp_loc_a101 PRIMARY KEY,
        cntry                 NVARCHAR(50)   NOT NULL,
        is_deleted            BIT            NOT NULL CONSTRAINT DF_silver_erp_loc_a101_del DEFAULT 0,
        dwh_batch_id          INT            NULL,
        dwh_source_bronze_id  BIGINT         NULL,
        dwh_create_date       DATETIME2(3)   NOT NULL CONSTRAINT DF_silver_erp_loc_a101_cre DEFAULT SYSDATETIME(),
        dwh_update_date       DATETIME2(3)   NOT NULL CONSTRAINT DF_silver_erp_loc_a101_upd DEFAULT SYSDATETIME(),
        dwh_row_hash          VARBINARY(32)  NOT NULL,
        dwh_row_version       ROWVERSION     NOT NULL
    );
END;
GO

-- =============================================================================
-- silver.erp_px_cat_g1v2
-- =============================================================================
IF OBJECT_ID(N'silver.erp_px_cat_g1v2', N'U') IS NULL
BEGIN
    CREATE TABLE silver.erp_px_cat_g1v2 (
        id                    NVARCHAR(50)   NOT NULL CONSTRAINT PK_silver_erp_px_cat_g1v2 PRIMARY KEY,
        cat                   NVARCHAR(50)   NULL,
        subcat                NVARCHAR(50)   NULL,
        maintenance           NVARCHAR(50)   NOT NULL,
        is_deleted            BIT            NOT NULL CONSTRAINT DF_silver_erp_px_cat_g1v2_del DEFAULT 0,
        dwh_batch_id          INT            NULL,
        dwh_source_bronze_id  BIGINT         NULL,
        dwh_create_date       DATETIME2(3)   NOT NULL CONSTRAINT DF_silver_erp_px_cat_g1v2_cre DEFAULT SYSDATETIME(),
        dwh_update_date       DATETIME2(3)   NOT NULL CONSTRAINT DF_silver_erp_px_cat_g1v2_upd DEFAULT SYSDATETIME(),
        dwh_row_hash          VARBINARY(32)  NOT NULL,
        dwh_row_version       ROWVERSION     NOT NULL
    );
END;
GO

-- =============================================================================
-- silver.rejected_records
-- =============================================================================
IF OBJECT_ID(N'silver.rejected_records', N'U') IS NULL
BEGIN
    CREATE TABLE silver.rejected_records (
        rejection_id      BIGINT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_silver_rejected_records PRIMARY KEY,
        batch_id          INT            NULL,
        rejection_stage   NVARCHAR(20)   NOT NULL,      -- INGESTION / SILVER
        source_table      NVARCHAR(256)  NOT NULL,
        source_record_id  NVARCHAR(200)  NULL,          -- landing_row_id or bronze_id
        file_id           INT            NULL,
        record_data       NVARCHAR(MAX)  NULL,          -- original values as JSON
        rejection_reason  NVARCHAR(1000) NOT NULL,
        rejected_at       DATETIME2(3)   NOT NULL CONSTRAINT DF_silver_rejected_at DEFAULT SYSDATETIME(),
        CONSTRAINT CK_silver_rejected_stage CHECK (rejection_stage IN (N'INGESTION', N'SILVER'))
    );
    CREATE INDEX IX_silver_rejected_records_batch ON silver.rejected_records (batch_id, source_table);
END;
GO

PRINT 'Silver tables ready.';
GO
