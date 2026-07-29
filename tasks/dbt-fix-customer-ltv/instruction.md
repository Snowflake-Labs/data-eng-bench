# dbt: Debug Customer Dimension Model

## Objective
The `dim_customers` model has issues. Investigate and fix all problems.

## Background
The analytics team flagged the `dim_customers` model as producing incorrect results. Numbers don't reconcile with upstream data. There may be multiple issues. Find and fix them all.

## Environment

- **DuckDB database**: `/app/database/retail.duckdb`
- **DuckDB dbt project**: `/app/dbt_models_duckdb`
- **Snowflake dbt project**: `/app/dbt_models_snowflake`

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

## Your Task
Find and fix the `dim_customers` model in the mart layer. Investigate the data lineage and compare the model output against upstream sources. Fix all issues you find.

## Success Criteria
- All customer-level metrics reconcile with upstream source data
- All tests pass

## Notes
- Do NOT modify upstream staging models
- Do NOT change model materialization type
- Do NOT remove or rename existing columns

## Guidelines

- The SQL must work on both DuckDB and Snowflake. Use Jinja conditionals (`{% if target.type == 'snowflake' %}`) where syntax differs between backends. **Important**: Boolean columns like `is_cancelled` may be stored differently across backends. DuckDB uses native booleans, but Snowflake may store them as VARCHAR. Use Jinja conditionals to handle this difference -- don't assume `= false` works everywhere.
