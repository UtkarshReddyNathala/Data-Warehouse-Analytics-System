/*
===============================================================================
Deploy All Warehouse Objects (SQLCMD script)
===============================================================================
In short:
    The list of every script needed to build the warehouse, in the right order.
    It is run by 00_deploy_all.sql (SSMS) or deploy/deploy.sh (Docker), not on
    its own.

Script Purpose:
    Creates or updates every schema, table, procedure and view in dependency
    order, configures the data folder and enables CDC. Re-runnable: tables are
    only created when missing, procedures/views use CREATE OR ALTER.

    Do not open this file directly in SSMS. Use scripts/00_deploy_all.sql
    (SSMS, SQLCMD mode) or deploy/deploy.sh (Docker), which set the variables:

        $(RepoRoot)      repository folder, e.g. C:\projects\Data-Warehouse-and-Analytics-System
        $(DataRoot)      folder with crm/ and erp/ CSV files, as seen by SQL Server
        $(BulkCodepage)  65001 on Windows, RAW on Linux
===============================================================================
*/
:on error exit

PRINT '>> 1/6 Schemas, audit and control tables';
:r "$(RepoRoot)/scripts/initialization/create_schemas.sql"
:r "$(RepoRoot)/scripts/audit/ddl_audit.sql"
:r "$(RepoRoot)/scripts/audit/proc_audit_logging.sql"

PRINT '>> 2/6 Landing, source, Bronze, Silver and Gold tables';
:r "$(RepoRoot)/scripts/source/ddl_source.sql"
:r "$(RepoRoot)/scripts/bronze/ddl_bronze.sql"
:r "$(RepoRoot)/scripts/silver/ddl_silver.sql"
:r "$(RepoRoot)/scripts/gold/ddl_gold.sql"

PRINT '>> 3/6 Metadata configuration and data quality rules';
:r "$(RepoRoot)/scripts/metadata/ddl_etl_config.sql"
:r "$(RepoRoot)/scripts/data_quality/ddl_dq_framework.sql"

PRINT '>> 4/6 Framework procedures';
:r "$(RepoRoot)/scripts/metadata/proc_validate_config.sql"
:r "$(RepoRoot)/scripts/cdc/proc_cdc_framework.sql"
:r "$(RepoRoot)/scripts/source/proc_ingest_source_file.sql"
:r "$(RepoRoot)/scripts/bronze/proc_load_bronze.sql"
:r "$(RepoRoot)/scripts/silver/proc_load_silver.sql"
:r "$(RepoRoot)/scripts/gold/proc_load_gold.sql"
:r "$(RepoRoot)/scripts/gold/ddl_gold_views.sql"
:r "$(RepoRoot)/scripts/data_quality/proc_run_dq_checks.sql"
:r "$(RepoRoot)/scripts/metadata/proc_load_metadata_driven.sql"
:r "$(RepoRoot)/scripts/init_load_all.sql"
:r "$(RepoRoot)/scripts/performance/proc_measure_query.sql"

PRINT '>> 5/6 Settings';
USE DataWarehouse;
GO
EXEC etl.usp_set_setting N'data_root', N'$(DataRoot)';
EXEC etl.usp_set_setting N'bulk_insert_codepage', N'$(BulkCodepage)';
GO

PRINT '>> 6/6 Enable CDC and validate the configuration';
EXEC etl.usp_enable_cdc;
GO
EXEC etl.usp_validate_config @raise_error = 1, @return_results = 1;
GO

PRINT '================================================';
PRINT 'Deployment complete. Run the pipeline with:';
PRINT '    EXEC DataWarehouse.etl.usp_run_pipeline;';
PRINT '================================================';
GO
