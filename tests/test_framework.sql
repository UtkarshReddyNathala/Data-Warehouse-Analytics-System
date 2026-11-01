/*
===============================================================================
Minimal T-SQL Test Framework
===============================================================================
In short:
    Small helper procedures used by every test: start a test run, check a
    result, and print a summary. A test run fails loudly if any check fails.

Script Purpose:
    Small helpers used by every test script in this folder.

    test.usp_begin_run   @suite         starts a test run (stored in SESSION_CONTEXT)
    test.usp_assert      @name, @passed, @details
    test.usp_assert_equals @name, @expected, @actual
    test.usp_end_run                    prints the summary and THROWS when an
                                        assertion failed (so CI fails too)
    test.usp_run_pipeline               runs the pipeline quietly (no files,
                                        no result set) and returns the batch id

WARNING:
    The tests change data in the source tables and run the pipeline. Run them
    on a development database only. Every test removes its own test rows at
    the end (test keys use the 99000000+ range and the 'SO_TEST' prefix).
===============================================================================
*/

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

USE DataWarehouse;
GO

IF SCHEMA_ID(N'test') IS NULL EXEC (N'CREATE SCHEMA test');
GO

IF OBJECT_ID(N'test.test_run', N'U') IS NULL
    CREATE TABLE test.test_run (
        run_id      INT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_test_run PRIMARY KEY,
        suite_name  NVARCHAR(200) NOT NULL,
        started_at  DATETIME2(3)  NOT NULL CONSTRAINT DF_test_run_start DEFAULT SYSDATETIME(),
        finished_at DATETIME2(3)  NULL,
        passed      INT           NULL,
        failed      INT           NULL
    );
GO

IF OBJECT_ID(N'test.test_result', N'U') IS NULL
    CREATE TABLE test.test_result (
        result_id   INT IDENTITY(1, 1) NOT NULL CONSTRAINT PK_test_result PRIMARY KEY,
        run_id      INT            NOT NULL,
        test_name   NVARCHAR(400)  NOT NULL,
        passed      BIT            NOT NULL,
        details     NVARCHAR(4000) NULL,
        executed_at DATETIME2(3)   NOT NULL CONSTRAINT DF_test_result_time DEFAULT SYSDATETIME()
    );
GO

CREATE OR ALTER PROCEDURE test.usp_begin_run @suite NVARCHAR(200)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @run_id INT;
    INSERT INTO test.test_run (suite_name) VALUES (@suite);
    SET @run_id = SCOPE_IDENTITY();
    EXEC sys.sp_set_session_context @key = N'test_run_id', @value = @run_id;
    PRINT '==================== TEST SUITE: ' + @suite + ' (run ' + CAST(@run_id AS NVARCHAR(10)) + ')';
END;
GO

CREATE OR ALTER PROCEDURE test.usp_assert
    @name    NVARCHAR(400),
    @passed  BIT,
    @details NVARCHAR(4000) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @run_id INT = CAST(SESSION_CONTEXT(N'test_run_id') AS INT);
    SET @passed = ISNULL(@passed, 0);

    INSERT INTO test.test_result (run_id, test_name, passed, details)
    VALUES (ISNULL(@run_id, 0), @name, @passed, @details);

    PRINT CASE WHEN @passed = 1 THEN '  [PASS] ' ELSE '  [FAIL] ' END + @name
        + CASE WHEN @passed = 0 AND @details IS NOT NULL THEN ' -> ' + @details ELSE '' END;
END;
GO

CREATE OR ALTER PROCEDURE test.usp_assert_equals
    @name     NVARCHAR(400),
    @expected SQL_VARIANT,
    @actual   SQL_VARIANT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @passed BIT = CASE WHEN @expected = @actual OR (@expected IS NULL AND @actual IS NULL) THEN 1 ELSE 0 END;
    DECLARE @details NVARCHAR(4000) = N'expected ' + ISNULL(CAST(@expected AS NVARCHAR(1000)), N'NULL')
                                    + N', actual ' + ISNULL(CAST(@actual AS NVARCHAR(1000)), N'NULL');
    EXEC test.usp_assert @name, @passed, @details;
END;
GO

CREATE OR ALTER PROCEDURE test.usp_end_run
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @run_id INT = CAST(SESSION_CONTEXT(N'test_run_id') AS INT);
    DECLARE @passed INT, @failed INT, @msg NVARCHAR(2048);

    SELECT @passed = SUM(CASE WHEN passed = 1 THEN 1 ELSE 0 END),
           @failed = SUM(CASE WHEN passed = 0 THEN 1 ELSE 0 END)
    FROM test.test_result WHERE run_id = @run_id;

    UPDATE test.test_run SET finished_at = SYSDATETIME(), passed = ISNULL(@passed, 0), failed = ISNULL(@failed, 0)
    WHERE run_id = @run_id;

    PRINT '==================== RESULT: ' + CAST(ISNULL(@passed, 0) AS NVARCHAR(10)) + ' passed, '
        + CAST(ISNULL(@failed, 0) AS NVARCHAR(10)) + ' failed';

    IF @failed > 0
    BEGIN
        SET @msg = N'Test run ' + CAST(@run_id AS NVARCHAR(10)) + N' has ' + CAST(@failed AS NVARCHAR(10))
                 + N' failed assertion(s). SELECT * FROM test.test_result WHERE run_id = ' + CAST(@run_id AS NVARCHAR(10)) + N' AND passed = 0;';
        THROW 51000, @msg, 1;
    END;
END;
GO

CREATE OR ALTER PROCEDURE test.usp_run_pipeline
    @batch_id           INT = NULL OUTPUT,
    @run_file_ingestion BIT = 0,
    @force_file_reload  BIT = 0,
    @force_cdc_resync   BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    EXEC etl.usp_run_pipeline
         @run_file_ingestion = @run_file_ingestion,
         @force_file_reload  = @force_file_reload,
         @force_cdc_resync   = @force_cdc_resync,
         @return_summary     = 0,
         @batch_id           = @batch_id OUTPUT;
END;
GO

PRINT 'Test framework ready.';
GO
