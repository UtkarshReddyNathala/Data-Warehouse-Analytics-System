/*
===============================================================================
Run All Pipeline Tests (SQLCMD script)
===============================================================================
In short:
    Runs every automated test, one suite after another, and stops at the first
    failure. Use it on a development database only.

Runs every automated test suite. Each suite THROWS when an assertion fails,
and ':on error exit' stops at the first failing suite.

SSMS:   enable SQLCMD mode, set RepoRoot below, run.
Docker: deploy/deploy.sh --test

Run on a DEVELOPMENT database only: the tests change source rows and run the
pipeline many times (each suite cleans up after itself).

Results:  SELECT * FROM test.test_run ORDER BY run_id DESC;
          SELECT * FROM test.test_result WHERE passed = 0;
===============================================================================
*/
:on error exit

:r "$(RepoRoot)/tests/test_framework.sql"
:r "$(RepoRoot)/tests/metadata_driven_etl/test_metadata_config.sql"
:r "$(RepoRoot)/tests/ingestion/test_file_ingestion.sql"
:r "$(RepoRoot)/tests/cdc/test_cdc_capture.sql"
:r "$(RepoRoot)/tests/incremental_loading/test_incremental_loading.sql"
:r "$(RepoRoot)/tests/scd_validation/test_scd_type2.sql"
:r "$(RepoRoot)/tests/pipeline_tests/test_failure_recovery.sql"
:r "$(RepoRoot)/tests/pipeline_tests/test_idempotency.sql"

SELECT run_id, suite_name, started_at, finished_at, passed, failed
FROM DataWarehouse.test.test_run
ORDER BY run_id DESC;
GO
