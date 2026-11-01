/*
===============================================================================
00_deploy_all.sql  -  One-click deployment for SSMS / Azure Data Studio
===============================================================================
In short:
    The easiest way to install the warehouse from SSMS. Set the folder paths at
    the top, run it once, and it creates every table, procedure and view.

How to use (SSMS):
    1. Query menu -> enable "SQLCMD Mode".
    2. Edit the three :setvar lines below.
       - RepoRoot : the folder where you cloned this repository
       - DataRoot : the data folder AS SEEN BY THE SQL SERVER SERVICE, ending
                    with a path separator. The service account needs read access.
       - BulkCodepage : 65001 (UTF-8) on Windows. Use RAW on SQL Server for Linux.
    3. (First time / reset) run scripts/init_database.sql
    4. Execute this script (F5).
    5. Run the pipeline:  EXEC DataWarehouse.etl.usp_run_pipeline;

Requirements:
    SQL Server 2019 or later (2017 works for most features), Developer,
    Standard or Enterprise edition (for CDC), SQL Server Agent running.
===============================================================================
*/

:setvar RepoRoot "C:\sql\dwh_project"
:setvar DataRoot "C:\sql\dwh_project\data\"
:setvar BulkCodepage "65001"

:r "$(RepoRoot)\scripts\deploy_objects.sql"
