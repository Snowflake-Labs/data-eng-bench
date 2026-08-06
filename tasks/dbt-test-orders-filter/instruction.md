# Sales Report Data Quality Fix

The company's sales reports are including non-production orders. Finance has noticed that revenue numbers are slightly inflated because test orders, sample orders, and internal orders are being counted in production reports.

## Your Task

Investigate the orders data to understand which orders should be excluded from production reporting. Then create a dbt model that produces a clean `production_sales` table containing only legitimate customer orders.

## Files

- DuckDB dbt project: `/app/dbt_models_duckdb/` (run `dbt deps` before `dbt run`)
- Snowflake dbt project: `/app/dbt_models_snowflake/` (run `dbt deps` before `dbt run`)

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

## Required Output

### `main.production_sales`

| Column | Type | Description |
|--------|------|-------------|
| `order_id` | VARCHAR | Unique order identifier |
| `customer_id` | VARCHAR | Customer identifier |
| `order_date` | DATE | Date the order was placed |
| `grand_total` | DECIMAL | Order total amount |
| `status` | VARCHAR | Order status |

## Guidelines

- The output table should only contain real customer orders
- Exclude any orders that are flagged for testing, sampling, or internal use
- Preserve all columns from the orders table in your model (the above are the minimum required)
- Round monetary values to 2 decimal places where applicable
