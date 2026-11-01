/*
===============================================================================
DDL Script: Gold Layer - Physical Star Schema
===============================================================================
In short:
    Creates the Gold star schema used for reporting: customer, product and date
    dimensions plus the sales fact table. The customer table keeps history, so
    older sales still show the customer as they were at the time.

Script Purpose:
    Creates PHYSICAL dimension and fact tables (reporting views are defined
    separately in ddl_gold_views.sql).

    gold.dim_date        Calendar dimension, key = YYYYMMDD
    gold.dim_customers   SCD Type 2 (country, marital status) + Type 1 (names,
                         gender, birthdate). One row per customer VERSION.
    gold.dim_products    SCD Type 1, one row per product number (current version).
    gold.fact_sales      One row per order line (order number + product number).

    Design rules:
      - Surrogate keys are IDENTITY columns, generated once and never reused.
      - Every dimension has an "Unknown" member with key -1, so a fact row is
        never discarded when its customer/product arrives late.
      - Foreign keys enforce referential integrity between fact and dimensions.
      - A filtered unique index guarantees only ONE current version per customer.

    Reporting views (one current row per customer, active sales only) are in
    scripts/gold/ddl_gold_views.sql.

    This script is re-runnable: tables are created only when missing.
===============================================================================
*/

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

USE DataWarehouse;
GO

-- =============================================================================
-- gold.dim_date
-- =============================================================================
IF OBJECT_ID(N'gold.dim_date', N'U') IS NULL
BEGIN
    CREATE TABLE gold.dim_date (
        date_key        INT           NOT NULL CONSTRAINT PK_gold_dim_date PRIMARY KEY,   -- YYYYMMDD, -1 = unknown
        full_date       DATE          NULL,
        year_number     SMALLINT      NULL,
        quarter_number  TINYINT       NULL,
        month_number    TINYINT       NULL,
        month_name      NVARCHAR(20)  NULL,
        year_month      CHAR(7)       NULL,     -- 2013-05
        day_of_month    TINYINT       NULL,
        day_of_week     TINYINT       NULL,     -- 1 = Monday
        day_name        NVARCHAR(20)  NULL,
        week_of_year    TINYINT       NULL,     -- ISO week
        is_weekend      BIT           NULL
    );

    INSERT INTO gold.dim_date (date_key, full_date, month_name, day_name)
    VALUES (-1, NULL, N'Unknown', N'Unknown');
END;
GO

-- =============================================================================
-- gold.dim_customers  (SCD Type 2)
-- =============================================================================
IF OBJECT_ID(N'gold.dim_customers', N'U') IS NULL
BEGIN
    CREATE TABLE gold.dim_customers (
        customer_key     INT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_gold_dim_customers PRIMARY KEY,
        customer_id      INT            NOT NULL,     -- business key (CRM cst_id)
        customer_number  NVARCHAR(50)   NOT NULL,     -- business key (CRM cst_key)
        first_name       NVARCHAR(50)   NULL,         -- Type 1
        last_name        NVARCHAR(50)   NULL,         -- Type 1
        country          NVARCHAR(50)   NOT NULL,     -- Type 2
        marital_status   NVARCHAR(50)   NOT NULL,     -- Type 2
        gender           NVARCHAR(50)   NOT NULL,     -- Type 1
        birthdate        DATE           NULL,         -- Type 1
        create_date      DATE           NULL,         -- Type 1
        effective_date   DATETIME2(3)   NOT NULL,     -- version valid from (inclusive)
        expiry_date      DATETIME2(3)   NULL,         -- version valid until (exclusive), NULL = open
        is_current       BIT            NOT NULL,
        is_deleted       BIT            NOT NULL CONSTRAINT DF_gold_dim_customers_del DEFAULT 0,
        scd1_hash        VARBINARY(32)  NULL,
        scd2_hash        VARBINARY(32)  NULL,
        dwh_batch_id     INT            NULL,
        dwh_insert_date  DATETIME2(3)   NOT NULL CONSTRAINT DF_gold_dim_customers_ins DEFAULT SYSDATETIME(),
        dwh_update_date  DATETIME2(3)   NOT NULL CONSTRAINT DF_gold_dim_customers_upd DEFAULT SYSDATETIME(),
        CONSTRAINT CK_gold_dim_customers_dates CHECK (expiry_date IS NULL OR expiry_date > effective_date),
        CONSTRAINT CK_gold_dim_customers_current CHECK (NOT (is_current = 1 AND expiry_date IS NOT NULL))
    );

    -- Only one current version per business key
    CREATE UNIQUE INDEX UX_gold_dim_customers_current
        ON gold.dim_customers (customer_id) WHERE is_current = 1;

    -- Point-in-time lookups for facts
    CREATE INDEX IX_gold_dim_customers_lookup
        ON gold.dim_customers (customer_id, effective_date) INCLUDE (expiry_date, is_current);

    SET IDENTITY_INSERT gold.dim_customers ON;
    INSERT INTO gold.dim_customers (customer_key, customer_id, customer_number, first_name, last_name, country,
                                    marital_status, gender, effective_date, expiry_date, is_current)
    VALUES (-1, -1, N'UNKNOWN', N'Unknown', N'Unknown', N'n/a', N'n/a', N'n/a', '1900-01-01', NULL, 1);
    SET IDENTITY_INSERT gold.dim_customers OFF;
END;
GO

-- =============================================================================
-- gold.dim_products  (SCD Type 1)
-- =============================================================================
IF OBJECT_ID(N'gold.dim_products', N'U') IS NULL
BEGIN
    CREATE TABLE gold.dim_products (
        product_key      INT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_gold_dim_products PRIMARY KEY,
        product_id       INT            NULL,         -- CRM prd_id of the current version
        product_number   NVARCHAR(50)   NOT NULL,     -- business key
        product_name     NVARCHAR(50)   NULL,
        category_id      NVARCHAR(50)   NULL,
        category         NVARCHAR(50)   NULL,
        subcategory      NVARCHAR(50)   NULL,
        maintenance      NVARCHAR(50)   NULL,
        cost             INT            NULL,
        product_line     NVARCHAR(50)   NULL,
        start_date       DATE           NULL,
        is_active        BIT            NOT NULL CONSTRAINT DF_gold_dim_products_active DEFAULT 1,
        scd1_hash        VARBINARY(32)  NULL,
        dwh_batch_id     INT            NULL,
        dwh_insert_date  DATETIME2(3)   NOT NULL CONSTRAINT DF_gold_dim_products_ins DEFAULT SYSDATETIME(),
        dwh_update_date  DATETIME2(3)   NOT NULL CONSTRAINT DF_gold_dim_products_upd DEFAULT SYSDATETIME(),
        CONSTRAINT UQ_gold_dim_products_number UNIQUE (product_number)
    );

    SET IDENTITY_INSERT gold.dim_products ON;
    INSERT INTO gold.dim_products (product_key, product_id, product_number, product_name, category_id, category,
                                   subcategory, maintenance, cost, product_line, is_active)
    VALUES (-1, -1, N'UNKNOWN', N'Unknown', N'n/a', N'Unknown', N'Unknown', N'n/a', 0, N'n/a', 1);
    SET IDENTITY_INSERT gold.dim_products OFF;
END;
GO

-- =============================================================================
-- gold.fact_sales
-- =============================================================================
IF OBJECT_ID(N'gold.fact_sales', N'U') IS NULL
BEGIN
    CREATE TABLE gold.fact_sales (
        sales_key          BIGINT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_gold_fact_sales PRIMARY KEY,
        order_number       NVARCHAR(50)  NOT NULL,     -- degenerate dimension
        product_number     NVARCHAR(50)  NOT NULL,     -- business key kept for late-arriving resolution
        customer_id        INT           NULL,         -- business key kept for late-arriving resolution
        product_key        INT           NOT NULL CONSTRAINT FK_fact_sales_product  REFERENCES gold.dim_products (product_key),
        customer_key       INT           NOT NULL CONSTRAINT FK_fact_sales_customer REFERENCES gold.dim_customers (customer_key),
        order_date_key     INT           NOT NULL CONSTRAINT FK_fact_sales_order_date REFERENCES gold.dim_date (date_key),
        shipping_date_key  INT           NOT NULL CONSTRAINT FK_fact_sales_ship_date  REFERENCES gold.dim_date (date_key),
        due_date_key       INT           NOT NULL CONSTRAINT FK_fact_sales_due_date   REFERENCES gold.dim_date (date_key),
        order_date         DATE          NULL,
        shipping_date      DATE          NULL,
        due_date           DATE          NULL,
        sales_amount       INT           NOT NULL,
        quantity           INT           NOT NULL,
        price              INT           NOT NULL,
        is_deleted         BIT           NOT NULL CONSTRAINT DF_gold_fact_sales_del DEFAULT 0,  -- deleted/cancelled in source
        dwh_batch_id       INT           NULL,
        dwh_insert_date    DATETIME2(3)  NOT NULL CONSTRAINT DF_gold_fact_sales_ins DEFAULT SYSDATETIME(),
        dwh_update_date    DATETIME2(3)  NOT NULL CONSTRAINT DF_gold_fact_sales_upd DEFAULT SYSDATETIME(),
        CONSTRAINT UQ_gold_fact_sales_line UNIQUE (order_number, product_number)
    );

    -- Fact foreign keys used in joins and filters
    CREATE INDEX IX_gold_fact_sales_customer   ON gold.fact_sales (customer_key) INCLUDE (sales_amount, quantity, order_date);
    CREATE INDEX IX_gold_fact_sales_product    ON gold.fact_sales (product_key)  INCLUDE (sales_amount, quantity, order_date);
    CREATE INDEX IX_gold_fact_sales_order_date ON gold.fact_sales (order_date_key) INCLUDE (sales_amount, quantity, customer_key, product_key);
END;
GO

PRINT 'Gold star schema tables ready.';
GO
