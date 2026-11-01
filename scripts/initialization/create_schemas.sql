/*
===============================================================================
Create Schemas (re-runnable)
===============================================================================
In short:
    Creates the schemas (folders) that group the warehouse objects: landing,
    source, bronze, silver, gold, audit and etl. It is safe to run more than
    once.

Script Purpose:
    Creates every schema used by the warehouse. Safe to run multiple times.

    landing : raw text copies of the CSV files (truncated on every file load)
    source  : simulated operational CRM / ERP databases (CDC is enabled here)
    bronze  : append-only record of everything extracted from the source
    silver  : cleaned, standardised, deduplicated current state
    gold    : star schema (physical dimension and fact tables + reporting views)
    audit   : configuration, watermarks, logging, data quality results
    etl     : framework stored procedures (orchestration, CDC, validation)

    NOTE: The schema name 'cdc' is reserved by SQL Server Change Data Capture.
          It is created automatically by sys.sp_cdc_enable_db, never by us.
===============================================================================
*/

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

USE DataWarehouse;
GO

IF SCHEMA_ID(N'landing') IS NULL EXEC (N'CREATE SCHEMA landing');
IF SCHEMA_ID(N'source')  IS NULL EXEC (N'CREATE SCHEMA source');
IF SCHEMA_ID(N'bronze')  IS NULL EXEC (N'CREATE SCHEMA bronze');
IF SCHEMA_ID(N'silver')  IS NULL EXEC (N'CREATE SCHEMA silver');
IF SCHEMA_ID(N'gold')    IS NULL EXEC (N'CREATE SCHEMA gold');
IF SCHEMA_ID(N'audit')   IS NULL EXEC (N'CREATE SCHEMA audit');
IF SCHEMA_ID(N'etl')     IS NULL EXEC (N'CREATE SCHEMA etl');
GO

PRINT 'Schemas ready: landing, source, bronze, silver, gold, audit, etl.';
GO
