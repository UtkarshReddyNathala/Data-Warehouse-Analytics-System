/*
===============================================================================
DDL Script: Bronze Tables (append-only change record)
===============================================================================
In short:
    Creates the Bronze tables, a permanent record of every change that came from
    the source. Rows are only ever added, never changed or deleted.

Script Purpose:
    Bronze is the reliable record of WHAT arrived from the source and WHEN.
    Rows are only ever appended - never updated or truncated by the pipeline.

    Every Bronze table has the source business columns plus these metadata
    columns:

    bronze_id         Ever-increasing row id. Silver uses it as its watermark.
    batch_id          Pipeline batch that extracted the row.
    load_type         CDC / INCREMENTAL / FULL.
    change_operation  I = insert, U = update (after image), B = update (before
                      image), D = delete, S = snapshot row (full extract).
    is_full_snapshot  1 when the row belongs to a complete snapshot of the source
                      table (initial load, FULL load or CDC re-synchronisation).
                      Silver uses it to detect rows that disappeared.
    cdc_start_lsn     Commit LSN of the change (CDC only).
    cdc_seqval        Order of the change inside the transaction (CDC only).
    source_file_id    Last file (audit.file_ingestion_log) that fed the source table.
    extracted_at      When the row was written to Bronze.

    This script is re-runnable: tables are only created when missing.
===============================================================================
*/

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

USE DataWarehouse;
GO

-- =============================================================================
-- bronze.crm_cust_info
-- =============================================================================
IF OBJECT_ID(N'bronze.crm_cust_info', N'U') IS NULL
BEGIN
    CREATE TABLE bronze.crm_cust_info (
        bronze_id           BIGINT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_bronze_crm_cust_info PRIMARY KEY,
        batch_id            INT           NOT NULL,
        load_type           NVARCHAR(20)  NOT NULL,
        change_operation    CHAR(1)       NOT NULL CONSTRAINT CK_bronze_crm_cust_info_op CHECK (change_operation IN ('I', 'U', 'B', 'D', 'S')),
        is_full_snapshot    BIT           NOT NULL CONSTRAINT DF_bronze_crm_cust_info_snap DEFAULT 0,
        cdc_start_lsn       BINARY(10)    NULL,
        cdc_seqval          BINARY(10)    NULL,
        source_file_id      INT           NULL,
        extracted_at        DATETIME2(3)  NOT NULL CONSTRAINT DF_bronze_crm_cust_info_ext DEFAULT SYSDATETIME(),
        -- source columns
        cst_id              INT           NULL,
        cst_key             NVARCHAR(50)  NULL,
        cst_firstname       NVARCHAR(50)  NULL,
        cst_lastname        NVARCHAR(50)  NULL,
        cst_marital_status  NVARCHAR(50)  NULL,
        cst_gndr            NVARCHAR(50)  NULL,
        cst_create_date     DATE          NULL
    );
    CREATE INDEX IX_bronze_crm_cust_info_batch ON bronze.crm_cust_info (batch_id);
    CREATE INDEX IX_bronze_crm_cust_info_key   ON bronze.crm_cust_info (cst_id, bronze_id);
END;
GO

-- =============================================================================
-- bronze.crm_prd_info
-- =============================================================================
IF OBJECT_ID(N'bronze.crm_prd_info', N'U') IS NULL
BEGIN
    CREATE TABLE bronze.crm_prd_info (
        bronze_id         BIGINT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_bronze_crm_prd_info PRIMARY KEY,
        batch_id          INT           NOT NULL,
        load_type         NVARCHAR(20)  NOT NULL,
        change_operation  CHAR(1)       NOT NULL CONSTRAINT CK_bronze_crm_prd_info_op CHECK (change_operation IN ('I', 'U', 'B', 'D', 'S')),
        is_full_snapshot  BIT           NOT NULL CONSTRAINT DF_bronze_crm_prd_info_snap DEFAULT 0,
        cdc_start_lsn     BINARY(10)    NULL,
        cdc_seqval        BINARY(10)    NULL,
        source_file_id    INT           NULL,
        extracted_at      DATETIME2(3)  NOT NULL CONSTRAINT DF_bronze_crm_prd_info_ext DEFAULT SYSDATETIME(),
        prd_id            INT           NULL,
        prd_key           NVARCHAR(50)  NULL,
        prd_nm            NVARCHAR(50)  NULL,
        prd_cost          INT           NULL,
        prd_line          NVARCHAR(50)  NULL,
        prd_start_dt      DATE          NULL,
        prd_end_dt        DATE          NULL
    );
    CREATE INDEX IX_bronze_crm_prd_info_batch ON bronze.crm_prd_info (batch_id);
    CREATE INDEX IX_bronze_crm_prd_info_key   ON bronze.crm_prd_info (prd_id, bronze_id);
END;
GO

-- =============================================================================
-- bronze.crm_sales_details
-- =============================================================================
IF OBJECT_ID(N'bronze.crm_sales_details', N'U') IS NULL
BEGIN
    CREATE TABLE bronze.crm_sales_details (
        bronze_id         BIGINT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_bronze_crm_sales_details PRIMARY KEY,
        batch_id          INT           NOT NULL,
        load_type         NVARCHAR(20)  NOT NULL,
        change_operation  CHAR(1)       NOT NULL CONSTRAINT CK_bronze_crm_sales_details_op CHECK (change_operation IN ('I', 'U', 'B', 'D', 'S')),
        is_full_snapshot  BIT           NOT NULL CONSTRAINT DF_bronze_crm_sales_details_snap DEFAULT 0,
        cdc_start_lsn     BINARY(10)    NULL,
        cdc_seqval        BINARY(10)    NULL,
        source_file_id    INT           NULL,
        extracted_at      DATETIME2(3)  NOT NULL CONSTRAINT DF_bronze_crm_sales_details_ext DEFAULT SYSDATETIME(),
        sls_ord_num       NVARCHAR(50)  NULL,
        sls_prd_key       NVARCHAR(50)  NULL,
        sls_cust_id       INT           NULL,
        sls_order_dt      INT           NULL,
        sls_ship_dt       INT           NULL,
        sls_due_dt        INT           NULL,
        sls_sales         INT           NULL,
        sls_quantity      INT           NULL,
        sls_price         INT           NULL
    );
    CREATE INDEX IX_bronze_crm_sales_details_batch ON bronze.crm_sales_details (batch_id);
    CREATE INDEX IX_bronze_crm_sales_details_key   ON bronze.crm_sales_details (sls_ord_num, sls_prd_key, bronze_id);
END;
GO

-- =============================================================================
-- bronze.erp_cust_az12
-- =============================================================================
IF OBJECT_ID(N'bronze.erp_cust_az12', N'U') IS NULL
BEGIN
    CREATE TABLE bronze.erp_cust_az12 (
        bronze_id         BIGINT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_bronze_erp_cust_az12 PRIMARY KEY,
        batch_id          INT           NOT NULL,
        load_type         NVARCHAR(20)  NOT NULL,
        change_operation  CHAR(1)       NOT NULL CONSTRAINT CK_bronze_erp_cust_az12_op CHECK (change_operation IN ('I', 'U', 'B', 'D', 'S')),
        is_full_snapshot  BIT           NOT NULL CONSTRAINT DF_bronze_erp_cust_az12_snap DEFAULT 0,
        cdc_start_lsn     BINARY(10)    NULL,
        cdc_seqval        BINARY(10)    NULL,
        source_file_id    INT           NULL,
        extracted_at      DATETIME2(3)  NOT NULL CONSTRAINT DF_bronze_erp_cust_az12_ext DEFAULT SYSDATETIME(),
        cid               NVARCHAR(50)  NULL,
        bdate             DATE          NULL,
        gen               NVARCHAR(50)  NULL,
        modified_at       DATETIME2(3)  NULL,
        is_deleted        BIT           NULL
    );
    CREATE INDEX IX_bronze_erp_cust_az12_batch ON bronze.erp_cust_az12 (batch_id);
    CREATE INDEX IX_bronze_erp_cust_az12_key   ON bronze.erp_cust_az12 (cid, bronze_id);
END;
GO

-- =============================================================================
-- bronze.erp_loc_a101
-- =============================================================================
IF OBJECT_ID(N'bronze.erp_loc_a101', N'U') IS NULL
BEGIN
    CREATE TABLE bronze.erp_loc_a101 (
        bronze_id         BIGINT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_bronze_erp_loc_a101 PRIMARY KEY,
        batch_id          INT           NOT NULL,
        load_type         NVARCHAR(20)  NOT NULL,
        change_operation  CHAR(1)       NOT NULL CONSTRAINT CK_bronze_erp_loc_a101_op CHECK (change_operation IN ('I', 'U', 'B', 'D', 'S')),
        is_full_snapshot  BIT           NOT NULL CONSTRAINT DF_bronze_erp_loc_a101_snap DEFAULT 0,
        cdc_start_lsn     BINARY(10)    NULL,
        cdc_seqval        BINARY(10)    NULL,
        source_file_id    INT           NULL,
        extracted_at      DATETIME2(3)  NOT NULL CONSTRAINT DF_bronze_erp_loc_a101_ext DEFAULT SYSDATETIME(),
        cid               NVARCHAR(50)  NULL,
        cntry             NVARCHAR(50)  NULL,
        modified_at       DATETIME2(3)  NULL,
        is_deleted        BIT           NULL
    );
    CREATE INDEX IX_bronze_erp_loc_a101_batch ON bronze.erp_loc_a101 (batch_id);
    CREATE INDEX IX_bronze_erp_loc_a101_key   ON bronze.erp_loc_a101 (cid, bronze_id);
END;
GO

-- =============================================================================
-- bronze.erp_px_cat_g1v2
-- =============================================================================
IF OBJECT_ID(N'bronze.erp_px_cat_g1v2', N'U') IS NULL
BEGIN
    CREATE TABLE bronze.erp_px_cat_g1v2 (
        bronze_id         BIGINT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_bronze_erp_px_cat_g1v2 PRIMARY KEY,
        batch_id          INT           NOT NULL,
        load_type         NVARCHAR(20)  NOT NULL,
        change_operation  CHAR(1)       NOT NULL CONSTRAINT CK_bronze_erp_px_cat_g1v2_op CHECK (change_operation IN ('I', 'U', 'B', 'D', 'S')),
        is_full_snapshot  BIT           NOT NULL CONSTRAINT DF_bronze_erp_px_cat_g1v2_snap DEFAULT 0,
        cdc_start_lsn     BINARY(10)    NULL,
        cdc_seqval        BINARY(10)    NULL,
        source_file_id    INT           NULL,
        extracted_at      DATETIME2(3)  NOT NULL CONSTRAINT DF_bronze_erp_px_cat_g1v2_ext DEFAULT SYSDATETIME(),
        id                NVARCHAR(50)  NULL,
        cat               NVARCHAR(50)  NULL,
        subcat            NVARCHAR(50)  NULL,
        maintenance       NVARCHAR(50)  NULL
    );
    CREATE INDEX IX_bronze_erp_px_cat_g1v2_batch ON bronze.erp_px_cat_g1v2 (batch_id);
END;
GO

PRINT 'Bronze tables ready.';
GO
