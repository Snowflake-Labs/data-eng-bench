# dbt: Fix Category Performance Report

## Objective

Debug and fix a dbt mart model that is producing incorrect results.

## Background

The retail analytics team has flagged the `rpt_category_performance` model as producing suspicious numbers. Several stakeholders have raised concerns during recent reviews, but nobody has pinpointed exactly what is wrong. The report is used for monthly business reviews and category-level planning.

## Your Task

Investigate the `rpt_category_performance.sql` model, identify the root cause of the data quality issue(s), and fix the model.

- DuckDB: `/app/dbt_models_duckdb/models/marts/product/rpt_category_performance.sql`
- Snowflake: `/app/dbt_models_snowflake/models/marts/product/rpt_category_performance.sql`

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

## Data Sources

The model references several staging tables. Explore the database schema and the model's SQL to understand the data relationships.

## Success Criteria

1. The model produces accurate results that are consistent with the underlying source data
2. All tests pass

## Notes

- Do NOT modify upstream staging models
- Do NOT change model materialization
- Preserve all output columns

## Guidelines

- The SQL syntax should work on both DuckDB and Snowflake (ANSI SQL compatible)
