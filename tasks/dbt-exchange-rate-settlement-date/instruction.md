# Revenue FX Settlement Date Fix

Fix the exchange-rate timing in the existing dbt model.

## Objective

Update `fact_revenue.sql` to apply currency conversion using the **payment settlement date** (not the order date).

## Files

- DuckDB: `/app/dbt_models_duckdb/models/marts/finance/fact_revenue.sql`
- Snowflake: `/app/dbt_models_snowflake/models/marts/finance/fact_revenue.sql`

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

## Required Changes

### Settlement Date Rules

- Derive settlement date from payment records using the most recent settlement timestamp.
- If an order has **no payment record**, use `order_date` as the settlement date.

### FX Rate Rules

- Use the daily exchange-rate dimension to convert to USD based on the settlement date.
- USD amounts must remain unchanged.
- Handle missing rates sensibly (no missing or NULL FX rates in output).

### Output Requirements

Add the following columns to `fact_revenue`:

| Column | Type | Description |
|--------|------|-------------|
| `settlement_date` | DATE | Settlement date used for FX conversion |
| `fx_rate` | DECIMAL | Exchange rate used for conversion |
| `net_revenue_usd` | DECIMAL | `net_revenue * fx_rate`, rounded to 2 decimals |
| `total_revenue_usd` | DECIMAL | `total_revenue * fx_rate`, rounded to 2 decimals |

### Grain

Maintain the existing grain of the revenue fact output while incorporating settlement date.

## Success Criteria

1. All tests pass
2. FX rates are based on settlement date, not order date
3. Orders without payments use order_date as settlement_date

## Guidelines

- Do NOT modify upstream staging models
- Do NOT change model materialization
- Preserve all output columns
- The SQL syntax should work on both DuckDB and Snowflake (ANSI SQL compatible)
