/*
===============================================================================
DDL Script: Landing Tables and Simulated Operational Source Tables
===============================================================================
In short:
    Creates two sets of tables. The landing tables hold a raw text copy of each
    CSV file, and the source tables act like a real company database (CRM and
    ERP) that the warehouse reads changes from.

Script Purpose:
    1. landing.*  Raw text copies of the six CSV files. Every column is
                  NVARCHAR so that a badly formatted value never stops the
                  file load. Each landing table has a "bulk view" that exposes
                  only the CSV columns: BULK INSERT writes into the view while
                  the table adds a row number (landing_row_id) for lineage.

    2. source.*   Simulated operational CRM and ERP databases. These tables
                  have real primary keys like an operational system would.
                  - CRM tables are tracked with SQL Server CDC
                    (inserts, updates and deletes are captured from the log).
                  - ERP tables carry modified_at, is_deleted (soft delete) and a
                    ROWVERSION column used as an incremental watermark.

    3. source.cdc_heartbeat  Tiny CDC-enabled table used to confirm that the
                  CDC capture process has read the transaction log up to "now".

    NOTE: The original CSV values are kept as they are (extra spaces, codes,
          wrong dates). Cleaning happens in the Silver layer, not here.
===============================================================================
*/

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

USE DataWarehouse;
GO

-- =============================================================================
-- LANDING TABLES (raw text)
-- =============================================================================
IF OBJECT_ID(N'landing.crm_cust_info', N'U') IS NULL
    CREATE TABLE landing.crm_cust_info (
        landing_row_id      BIGINT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_landing_crm_cust_info PRIMARY KEY,
        cst_id              NVARCHAR(400) NULL,
        cst_key             NVARCHAR(400) NULL,
        cst_firstname       NVARCHAR(400) NULL,
        cst_lastname        NVARCHAR(400) NULL,
        cst_marital_status  NVARCHAR(400) NULL,
        cst_gndr            NVARCHAR(400) NULL,
        cst_create_date     NVARCHAR(400) NULL
    );
GO
CREATE OR ALTER VIEW landing.vw_crm_cust_info_bulk AS
SELECT cst_id, cst_key, cst_firstname, cst_lastname, cst_marital_status, cst_gndr, cst_create_date
FROM landing.crm_cust_info;
GO

IF OBJECT_ID(N'landing.crm_prd_info', N'U') IS NULL
    CREATE TABLE landing.crm_prd_info (
        landing_row_id  BIGINT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_landing_crm_prd_info PRIMARY KEY,
        prd_id          NVARCHAR(400) NULL,
        prd_key         NVARCHAR(400) NULL,
        prd_nm          NVARCHAR(400) NULL,
        prd_cost        NVARCHAR(400) NULL,
        prd_line        NVARCHAR(400) NULL,
        prd_start_dt    NVARCHAR(400) NULL,
        prd_end_dt      NVARCHAR(400) NULL
    );
GO
CREATE OR ALTER VIEW landing.vw_crm_prd_info_bulk AS
SELECT prd_id, prd_key, prd_nm, prd_cost, prd_line, prd_start_dt, prd_end_dt
FROM landing.crm_prd_info;
GO

IF OBJECT_ID(N'landing.crm_sales_details', N'U') IS NULL
    CREATE TABLE landing.crm_sales_details (
        landing_row_id  BIGINT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_landing_crm_sales_details PRIMARY KEY,
        sls_ord_num     NVARCHAR(400) NULL,
        sls_prd_key     NVARCHAR(400) NULL,
        sls_cust_id     NVARCHAR(400) NULL,
        sls_order_dt    NVARCHAR(400) NULL,
        sls_ship_dt     NVARCHAR(400) NULL,
        sls_due_dt      NVARCHAR(400) NULL,
        sls_sales       NVARCHAR(400) NULL,
        sls_quantity    NVARCHAR(400) NULL,
        sls_price       NVARCHAR(400) NULL
    );
GO
CREATE OR ALTER VIEW landing.vw_crm_sales_details_bulk AS
SELECT sls_ord_num, sls_prd_key, sls_cust_id, sls_order_dt, sls_ship_dt, sls_due_dt, sls_sales, sls_quantity, sls_price
FROM landing.crm_sales_details;
GO

IF OBJECT_ID(N'landing.erp_cust_az12', N'U') IS NULL
    CREATE TABLE landing.erp_cust_az12 (
        landing_row_id  BIGINT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_landing_erp_cust_az12 PRIMARY KEY,
        cid             NVARCHAR(400) NULL,
        bdate           NVARCHAR(400) NULL,
        gen             NVARCHAR(400) NULL
    );
GO
CREATE OR ALTER VIEW landing.vw_erp_cust_az12_bulk AS
SELECT cid, bdate, gen FROM landing.erp_cust_az12;
GO

IF OBJECT_ID(N'landing.erp_loc_a101', N'U') IS NULL
    CREATE TABLE landing.erp_loc_a101 (
        landing_row_id  BIGINT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_landing_erp_loc_a101 PRIMARY KEY,
        cid             NVARCHAR(400) NULL,
        cntry           NVARCHAR(400) NULL
    );
GO
CREATE OR ALTER VIEW landing.vw_erp_loc_a101_bulk AS
SELECT cid, cntry FROM landing.erp_loc_a101;
GO

IF OBJECT_ID(N'landing.erp_px_cat_g1v2', N'U') IS NULL
    CREATE TABLE landing.erp_px_cat_g1v2 (
        landing_row_id  BIGINT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_landing_erp_px_cat_g1v2 PRIMARY KEY,
        id              NVARCHAR(400) NULL,
        cat             NVARCHAR(400) NULL,
        subcat          NVARCHAR(400) NULL,
        maintenance     NVARCHAR(400) NULL
    );
GO
CREATE OR ALTER VIEW landing.vw_erp_px_cat_g1v2_bulk AS
SELECT id, cat, subcat, maintenance FROM landing.erp_px_cat_g1v2;
GO

-- =============================================================================
-- SOURCE TABLES: CRM (CDC-tracked, physical deletes)
-- =============================================================================
IF OBJECT_ID(N'source.crm_cust_info', N'U') IS NULL
    CREATE TABLE source.crm_cust_info (
        cst_id              INT           NOT NULL CONSTRAINT PK_source_crm_cust_info PRIMARY KEY,
        cst_key             NVARCHAR(50)  NULL,
        cst_firstname       NVARCHAR(50)  NULL,
        cst_lastname        NVARCHAR(50)  NULL,
        cst_marital_status  NVARCHAR(50)  NULL,
        cst_gndr            NVARCHAR(50)  NULL,
        cst_create_date     DATE          NULL
    );
GO

IF OBJECT_ID(N'source.crm_prd_info', N'U') IS NULL
    CREATE TABLE source.crm_prd_info (
        prd_id        INT           NOT NULL CONSTRAINT PK_source_crm_prd_info PRIMARY KEY,
        prd_key       NVARCHAR(50)  NULL,
        prd_nm        NVARCHAR(50)  NULL,
        prd_cost      INT           NULL,
        prd_line      NVARCHAR(50)  NULL,
        prd_start_dt  DATE          NULL,
        prd_end_dt    DATE          NULL
    );
GO

IF OBJECT_ID(N'source.crm_sales_details', N'U') IS NULL
    CREATE TABLE source.crm_sales_details (
        sls_ord_num   NVARCHAR(50)  NOT NULL,
        sls_prd_key   NVARCHAR(50)  NOT NULL,
        sls_cust_id   INT           NULL,
        sls_order_dt  INT           NULL,   -- operational system stores dates as YYYYMMDD integers
        sls_ship_dt   INT           NULL,
        sls_due_dt    INT           NULL,
        sls_sales     INT           NULL,
        sls_quantity  INT           NULL,
        sls_price     INT           NULL,
        CONSTRAINT PK_source_crm_sales_details PRIMARY KEY (sls_ord_num, sls_prd_key)
    );
GO

-- =============================================================================
-- SOURCE TABLES: ERP (watermark-based incremental, soft deletes)
-- =============================================================================
IF OBJECT_ID(N'source.erp_cust_az12', N'U') IS NULL
    CREATE TABLE source.erp_cust_az12 (
        cid          NVARCHAR(50)  NOT NULL CONSTRAINT PK_source_erp_cust_az12 PRIMARY KEY,
        bdate        DATE          NULL,
        gen          NVARCHAR(50)  NULL,
        modified_at  DATETIME2(3)  NOT NULL CONSTRAINT DF_source_erp_cust_az12_mod DEFAULT SYSDATETIME(),
        is_deleted   BIT           NOT NULL CONSTRAINT DF_source_erp_cust_az12_del DEFAULT 0,
        row_version  ROWVERSION    NOT NULL
    );
GO

IF OBJECT_ID(N'source.erp_loc_a101', N'U') IS NULL
    CREATE TABLE source.erp_loc_a101 (
        cid          NVARCHAR(50)  NOT NULL CONSTRAINT PK_source_erp_loc_a101 PRIMARY KEY,
        cntry        NVARCHAR(50)  NULL,
        modified_at  DATETIME2(3)  NOT NULL CONSTRAINT DF_source_erp_loc_a101_mod DEFAULT SYSDATETIME(),
        is_deleted   BIT           NOT NULL CONSTRAINT DF_source_erp_loc_a101_del DEFAULT 0,
        row_version  ROWVERSION    NOT NULL
    );
GO

-- Small reference table: loaded as a FULL snapshot every time it changes.
IF OBJECT_ID(N'source.erp_px_cat_g1v2', N'U') IS NULL
    CREATE TABLE source.erp_px_cat_g1v2 (
        id           NVARCHAR(50)  NOT NULL CONSTRAINT PK_source_erp_px_cat_g1v2 PRIMARY KEY,
        cat          NVARCHAR(50)  NULL,
        subcat       NVARCHAR(50)  NULL,
        maintenance  NVARCHAR(50)  NULL
    );
GO

-- Indexes that support the incremental watermark scans
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_source_erp_cust_az12_rowver')
    CREATE INDEX IX_source_erp_cust_az12_rowver ON source.erp_cust_az12 (row_version);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_source_erp_loc_a101_rowver')
    CREATE INDEX IX_source_erp_loc_a101_rowver ON source.erp_loc_a101 (row_version);
GO

-- =============================================================================
-- CDC heartbeat table
-- =============================================================================
IF OBJECT_ID(N'source.cdc_heartbeat', N'U') IS NULL
    CREATE TABLE source.cdc_heartbeat (
        heartbeat_id  INT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_source_cdc_heartbeat PRIMARY KEY,
        token         UNIQUEIDENTIFIER NOT NULL,
        created_at    DATETIME2(3)     NOT NULL CONSTRAINT DF_source_cdc_heartbeat_created DEFAULT SYSDATETIME()
    );
GO

PRINT 'Landing and source tables ready.';
GO
