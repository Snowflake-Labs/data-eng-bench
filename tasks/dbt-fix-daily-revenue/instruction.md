# dbt: Fix Daily Revenue Report

## Objective
Fix a dbt model with data quality issues in daily reporting.

## Background
The finance team relies on `rpt_order_daily_summary` to track daily revenue. They've reported issues with the report output.

## The Bug
The report has data quality problems. Some expected records are missing and calculations appear incorrect.

## Your Task
Fix the `rpt_order_daily_summary` model to produce correct output.

## Files
- DuckDB model: `/app/dbt_models_duckdb/models/marts/sales/rpt_order_daily_summary.sql`
- Snowflake model: `/app/dbt_models_snowflake/models/marts/sales/rpt_order_daily_summary.sql`
- Source data: `stg_orders__orders`

## Database Backend
This task supports two database backends:

- **DuckDB** (default): Local DuckDB database at `/app/database/retail.duckdb`. The dbt project is at `/app/dbt_models_duckdb/`.
- **Snowflake**: Cloud Snowflake database. Connection details are provided via environment variables (`SNOWFLAKE_ACCOUNT`, `SNOWFLAKE_USER`, `SNOWFLAKE_PASSWORD`, `SNOWFLAKE_DATABASE`, `SNOWFLAKE_SCHEMA`, `SNOWFLAKE_WAREHOUSE`, `SNOWFLAKE_ROLE`). The dbt project is at `/app/dbt_models_snowflake/`.

Check the `DB_TYPE` environment variable to determine which backend is active.

## dbt Profile Setup

Create a `profiles.yml` in the appropriate dbt project directory:

- For DuckDB: Configure with `type: duckdb` and `path` pointing to the database file.
- For Snowflake: Configure with `type: snowflake` and use the environment variables for connection settings (password authentication). Set the profile's `schema:` to `$SNOWFLAKE_SCHEMA` — do NOT leave it blank (a blank schema makes Snowflake default to `PUBLIC`, so models land in the wrong schema and the verifier cannot find them).

## Success Criteria
- Output produces complete and accurate results
- All dates in the range are present (no gaps)
- Cumulative revenue is calculated correctly
- All tests pass

## Guidelines
- Use Jinja conditionals (`{% if target.type == 'snowflake' %}`) for database-specific syntax
- Do NOT modify upstream staging models
- Do NOT change model materialization
- Preserve all output columns

## Notes
- Do NOT modify upstream staging models
- Do NOT change model materialization
- Preserve all output columns
