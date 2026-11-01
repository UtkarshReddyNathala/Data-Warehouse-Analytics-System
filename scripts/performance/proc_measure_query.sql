/*
===============================================================================
Stored Procedure: etl.usp_measure_query
===============================================================================
In short:
    Runs a query and saves how long it took and how much work it did. Use it to
    compare a query before and after a change, such as a new index.

Script Purpose:
    Runs a query and records its MEASURED cost in audit.perf_measurement:
    elapsed time, CPU time and logical reads, read from
    sys.dm_exec_query_stats for that exact execution.

    Use it to compare a query BEFORE and AFTER an optimisation (index,
    rewrite, columnstore). Only report numbers that this table contains.

    Requires VIEW SERVER STATE (sysadmin has it).

Usage:
    EXEC etl.usp_measure_query
         @query_name = N'Revenue by country',
         @phase      = N'BEFORE',
         @sql        = N'SELECT c.country, SUM(f.sales_amount) AS revenue FROM gold.vw_fact_sales f
                         JOIN gold.vw_dim_customers c ON c.customer_key = f.customer_key GROUP BY c.country';

    The query is wrapped as SELECT COUNT_BIG(*) FROM (<query>) AS q, so every
    column needs a name and ORDER BY is not allowed (it does not change cost
    measurement of the main work anyway).
===============================================================================
*/

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

USE DataWarehouse;
GO

CREATE OR ALTER PROCEDURE etl.usp_measure_query
    @query_name NVARCHAR(200),
    @phase      NVARCHAR(10),
    @sql        NVARCHAR(MAX),
    @notes      NVARCHAR(1000) = NULL,
    @runs       INT = 3            -- the fastest of N runs is recorded (warm cache)
AS
BEGIN
    SET NOCOUNT ON;

    IF @phase NOT IN (N'BEFORE', N'AFTER')
        THROW 50700, '@phase must be BEFORE or AFTER.', 1;

    DECLARE @tag NVARCHAR(100) = N'/* PERF:' + CONVERT(NVARCHAR(36), NEWID()) + N' */ ';
    DECLARE @i INT = 0;
    DECLARE @best TABLE (elapsed_ms INT, cpu_ms INT, logical_reads BIGINT);

    WHILE @i < @runs
    BEGIN
        -- Results are discarded: wrap the query so it does not return rows
        DECLARE @wrapped NVARCHAR(MAX) = @tag + N'SELECT @n = COUNT_BIG(*) FROM (' + @sql + N') AS q;';
        DECLARE @n BIGINT;
        EXEC sys.sp_executesql @wrapped, N'@n BIGINT OUTPUT', @n = @n OUTPUT;

        INSERT INTO @best (elapsed_ms, cpu_ms, logical_reads)
        SELECT TOP (1)
            CAST(qs.last_elapsed_time / 1000 AS INT),
            CAST(qs.last_worker_time  / 1000 AS INT),
            qs.last_logical_reads
        FROM sys.dm_exec_query_stats AS qs
        CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS t
        WHERE t.text LIKE N'%' + @tag + N'%'
          AND t.text NOT LIKE N'%dm_exec_query_stats%'
        ORDER BY qs.last_execution_time DESC;

        SET @i += 1;
    END;

    INSERT INTO audit.perf_measurement (query_name, phase, elapsed_ms, cpu_ms, logical_reads, notes)
    SELECT TOP (1) @query_name, @phase, elapsed_ms, cpu_ms, logical_reads, @notes
    FROM @best
    ORDER BY elapsed_ms;

    SELECT TOP (1) @query_name AS query_name, @phase AS phase, elapsed_ms, cpu_ms, logical_reads
    FROM @best ORDER BY elapsed_ms;
END;
GO
