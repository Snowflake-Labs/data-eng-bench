# dbt: Fix Sales Data Issue

## Objective

Fix a dbt model with data inconsistencies in sales reporting.

## Background

The data warehouse consolidates orders from multiple systems (SAP and POS). The operations team has reported that daily sales aggregations are incorrect, particularly around midnight hours.

## Your Task

Fix the `int_sales__orders_enriched.sql` model to produce correct output.

- DuckDB: `/app/dbt_models_duckdb/models/intermediate/sales/int_sales__orders_enriched.sql`
- Snowflake: `/app/dbt_models_snowflake/models/intermediate/sales/int_sales__orders_enriched.sql`

## Database Backend

This task supports both DuckDB and Snowflake. **Run `echo $DB_TYPE` in a shell BEFORE you write any code or spawn any subagents — the live env determines which backend the verifier runs against.** Do NOT assume a default from this prose. Both `/app/dbt_models_duckdb/` and `/app/dbt_models_snowflake/` exist on disk; the verifier only checks the project matching the live `$DB_TYPE`.

### DuckDB
- Set `DB_TYPE=duckdb`
- Database path: `$DUCKDB_PATH` (default: `/app/database/retail.duckdb`)

### Snowflake
- Set `DB_TYPE=snowflake`
- Environment variables (pre-configured):
  - `SNOWFLAKE_ACCOUNT`
  - `SNOWFLAKE_USER`
  - `SNOWFLAKE_PASSWORD`
  - `SNOWFLAKE_DATABASE` - The clone database to use
  - `SNOWFLAKE_SCHEMA`
  - `SNOWFLAKE_WAREHOUSE`
  - `SNOWFLAKE_ROLE` (optional)

**Note**: For Snowflake, the entrypoint automatically creates a clone database and sets `SNOWFLAKE_DATABASE`. The clone is destroyed when the task completes.

## dbt Profile Setup

You must configure dbt to connect to the database:
- Create a `profiles.yml` in the dbt project directory with profile name `retail_dw_master`
- Set `DBT_PROFILES_DIR` environment variable to the directory containing `profiles.yml`

### DuckDB Profile
Configure with `type: duckdb` and the database path from `$DUCKDB_PATH`.

### Snowflake Profile
Configure with `type: snowflake` using password authentication:
- Use the environment variables for account, user, password, database, schema, warehouse, and role
- Set the profile's `schema:` to `$SNOWFLAKE_SCHEMA` — do NOT leave it blank. A blank or omitted schema makes Snowflake silently default to `PUBLIC`, so your models get built in the wrong schema and the verifier cannot find them.

## The Bug

Data from different source systems is being processed inconsistently. Investigation shows that timestamps from POS and SAP systems are not aligned properly, causing incorrect aggregations when combining the data.

**Hints**:
1. The two source systems may store timestamps in different timezones. There is a 5-hour difference between the systems. You can solve this by either:
   - Adjusting POS timestamps forward 5 hours, OR
   - Adjusting SAP timestamps backward 5 hours, OR
   - Any other adjustment that results in both systems being aligned (5-hour total correction)

2. The timestamp fields in the staging tables use **MIXED formats** - the data quality is inconsistent. You'll find:
   - Standard SQL format: `YYYY-MM-DD HH:MM:SS`
   - American format: `mm/dd/yyyy` or `mm/dd/yyyy HH:MM:SS` (e.g., `07/23/2020`, `11/27/2023`)
   - European format: `dd/mm/yyyy` or `dd/mm/yyyy HH:MM:SS`
   - Compact format: `YYYYMMDD`
   - Unix timestamps: numeric values (seconds since epoch)

   You'll need to handle all these formats. Try American format before European format.

## Data Sources

- **stg_sap__vbak** - SAP order data with timestamps, amounts, and status fields. Explore the table to understand available columns.
- **stg_pos__transactions** - POS transaction data with timestamps, amounts, and status fields. Explore the table to understand available columns.

## Success Criteria

- Output produces correct aggregations
- All tests pass

## Notes

- Do NOT modify staging models
- Do NOT change model materialization (keep as view)
- Preserve all output columns

## Guidelines

- DuckDB and Snowflake have different function names for timestamp parsing, regex, and type casting. Use Jinja conditionals (`{% if target.type == 'snowflake' %}`) to handle backend-specific SQL where needed. For example, Snowflake uses `TRY_TO_TIMESTAMP(...)` while DuckDB uses `TRY_CAST(... AS TIMESTAMP)` or `strptime(...)`. Snowflake's `REGEXP_REPLACE` does global replacement by default (no `'g'` flag), while DuckDB requires `'g'`.
