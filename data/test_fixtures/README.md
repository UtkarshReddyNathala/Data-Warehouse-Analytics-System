# Test Files

These are small CSV files used only by `tests/ingestion/test_file_ingestion.sql`.

They are loaded into a temporary table, `source.test_customer`, using the normal file loading procedure (`etl.usp_ingest_source_file`). They are never loaded into the real warehouse tables.

Each file is a different situation, loaded one after another:

| File | What it tests |
|---|---|
| customers_v1_initial.csv | 5 valid customers |
| customers_v2_invalid_date.csv | Customer 3 has an invalid date, so that row is rejected but the customer must be kept, not deleted. Customer 2 has a new name |
| customers_v3_unreadable_key.csv | The key `X7` cannot be read, and customer 5 is missing. All deletes are paused, so customer 5 is not deleted |
| customers_v3b_blank_key.csv | Customer 5's key is blank. All deletes are paused, and customer 5 is kept |
| customers_v4_duplicate_key.csv | Customer 1 appears twice. The last row wins and the other row is rejected |
| customers_v5_mostly_missing.csv | Only 1 of the 5 customers is in the file. The whole load is rejected by the safety limit |
| customers_v6_one_deleted.csv | Customer 5 is really removed, so it is deleted from the source table |
