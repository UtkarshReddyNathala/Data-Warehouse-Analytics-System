/*
===============================================================================
Stored Procedure: etl.usp_run_dq_checks
===============================================================================
In short:
    Runs every active data quality rule for Silver or Gold and saves the
    results. If a critical rule fails, the pipeline stops before bad data
    reaches the reports.

Script Purpose:
    Executes every active rule of one layer (SILVER or GOLD) from audit.dq_rule
    and writes one result row per rule into audit.dq_result.

    Status per rule:
      PASSED   no failing rows (or failure rate within threshold_pct)
      WARNING  failures on a WARNING rule
      FAILED   failures on a CRITICAL rule
      ERROR    the rule itself could not run (counted as critical)

    The procedure returns the number of critical failures and warnings; the
    master pipeline decides whether to stop (setting dq_stop_on_critical).

Usage:
    DECLARE @c INT, @w INT;
    EXEC etl.usp_run_dq_checks @batch_id = NULL, @layer = N'SILVER',
         @critical_failures = @c OUTPUT, @warnings = @w OUTPUT;
    SELECT * FROM audit.dq_result WHERE result_id > (SELECT MAX(result_id) - 50 FROM audit.dq_result);
===============================================================================
*/

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

USE DataWarehouse;
GO

CREATE OR ALTER PROCEDURE etl.usp_run_dq_checks
    @batch_id          INT = NULL,
    @layer             NVARCHAR(10),
    @critical_failures INT = 0 OUTPUT,
    @warnings          INT = 0 OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT @critical_failures = 0, @warnings = 0;

    DECLARE @rules TABLE (rule_id INT PRIMARY KEY);
    INSERT INTO @rules (rule_id)
    SELECT rule_id FROM audit.dq_rule WHERE layer = @layer AND is_active = 1;

    DECLARE @rule_id INT, @rule_name NVARCHAR(200), @table_name NVARCHAR(256), @category NVARCHAR(30),
            @severity NVARCHAR(10), @rule_type NVARCHAR(10), @condition NVARCHAR(2000), @custom NVARCHAR(MAX),
            @filter NVARCHAR(1000), @threshold DECIMAL(9, 4), @table2 NVARCHAR(300);
    DECLARE @sql NVARCHAR(MAX), @checked BIGINT, @failed BIGINT, @pct DECIMAL(9, 4), @status NVARCHAR(10), @error NVARCHAR(4000);

    WHILE EXISTS (SELECT 1 FROM @rules)
    BEGIN
        SELECT TOP (1) @rule_id = r.rule_id
        FROM @rules AS r ORDER BY r.rule_id;

        SELECT @rule_name = rule_name, @table_name = table_name, @category = category, @severity = severity,
               @rule_type = rule_type, @condition = failure_condition, @custom = custom_failed_sql,
               @filter = row_filter, @threshold = threshold_pct
        FROM audit.dq_rule WHERE rule_id = @rule_id;

        SELECT @checked = NULL, @failed = NULL, @pct = NULL, @error = NULL;
        SET @table2 = QUOTENAME(PARSENAME(@table_name, 2)) + N'.' + QUOTENAME(PARSENAME(@table_name, 1));

        BEGIN TRY
            IF @rule_type = N'CONDITION'
                SET @sql = N'SELECT @checked = COUNT_BIG(*), '
                         + N'@failed = ISNULL(SUM(CASE WHEN ' + @condition + N' THEN CAST(1 AS BIGINT) ELSE 0 END), 0) '
                         + N'FROM ' + @table2 + ISNULL(N' WHERE ' + @filter, N'') + N';';
            ELSE
                SET @sql = N'SELECT @checked = COUNT_BIG(*) FROM ' + @table2 + ISNULL(N' WHERE ' + @filter, N'') + N'; '
                         + N'SELECT @failed = COUNT_BIG(*) FROM (' + @custom + N') AS q;';

            EXEC sys.sp_executesql @sql, N'@checked BIGINT OUTPUT, @failed BIGINT OUTPUT',
                 @checked = @checked OUTPUT, @failed = @failed OUTPUT;

            SET @pct = CASE WHEN @checked > 0 THEN CAST(@failed * 100.0 / @checked AS DECIMAL(9, 4))
                            WHEN @failed > 0 THEN 100 ELSE 0 END;

            SET @status = CASE
                WHEN @failed = 0 OR (@threshold > 0 AND @pct <= @threshold) THEN N'PASSED'
                WHEN @severity = N'CRITICAL' THEN N'FAILED'
                ELSE N'WARNING' END;
        END TRY
        BEGIN CATCH
            SET @status = N'ERROR';
            SET @error = LEFT(ERROR_MESSAGE(), 4000);
        END CATCH;

        INSERT INTO audit.dq_result (batch_id, rule_id, rule_name, layer, table_name, category, severity,
                                     records_checked, records_failed, failed_pct, status, error_message)
        VALUES (@batch_id, @rule_id, @rule_name, @layer, @table_name, @category, @severity,
                @checked, @failed, @pct, @status, @error);

        IF @status IN (N'FAILED', N'ERROR') SET @critical_failures += 1;
        IF @status = N'WARNING'             SET @warnings += 1;

        DELETE FROM @rules WHERE rule_id = @rule_id;
    END;
END;
GO
