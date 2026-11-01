/*
===============================================================================
RESET SCRIPT: Drop and Recreate the DataWarehouse Database
===============================================================================
In short:
    Deletes the DataWarehouse database (if it exists) and creates a new, empty
    one. Run it only when you want a clean start, because all data is lost.

Script Purpose:
    Drops the 'DataWarehouse' database (if it exists) and creates a fresh, empty
    database. This is a RESET script. It is intentionally separated from the
    normal execution scripts, which are all re-runnable and never drop data.

    After running this script, deploy the objects with:
        scripts/00_deploy_all.sql   (SQLCMD mode)

    The database owner is set to [sa] because SQL Server Change Data Capture
    needs a valid database owner for its capture and cleanup jobs.

WARNING:
    Running this script permanently deletes ALL data in 'DataWarehouse'.
===============================================================================
*/

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

USE master;
GO

IF EXISTS (SELECT 1 FROM sys.databases WHERE name = N'DataWarehouse')
BEGIN
    -- Disable CDC first so that its SQL Server Agent jobs are removed cleanly.
    IF EXISTS (SELECT 1 FROM sys.databases WHERE name = N'DataWarehouse' AND is_cdc_enabled = 1)
    BEGIN
        EXEC (N'USE DataWarehouse; EXEC sys.sp_cdc_disable_db;');
    END;

    ALTER DATABASE DataWarehouse SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE DataWarehouse;
END;
GO

CREATE DATABASE DataWarehouse;
GO

-- Simple recovery is enough for a development warehouse. CDC works in SIMPLE
-- recovery: log truncation simply waits until the capture job has read the log.
ALTER DATABASE DataWarehouse SET RECOVERY SIMPLE;
GO

-- CDC capture/cleanup jobs need a valid database owner.
BEGIN TRY
    ALTER AUTHORIZATION ON DATABASE::DataWarehouse TO [sa];
END TRY
BEGIN CATCH
    PRINT 'WARNING: Could not set the database owner to [sa]: ' + ERROR_MESSAGE();
    PRINT '         CDC requires a valid database owner. Set one manually if CDC fails.';
END CATCH;
GO

PRINT 'Database DataWarehouse created. Next step: run scripts/00_deploy_all.sql in SQLCMD mode.';
GO
