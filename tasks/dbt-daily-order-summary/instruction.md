# Daily Order Summary

The operations team needs a daily view of order activity to plan staffing and logistics. They want to track order volume and revenue trends over time, excluding cancelled or failed orders.

## Your Task

Create a **standalone dbt project** at `/app/dbt_project` with a model called `daily_order_summary` that aggregates orders by date.

**Important**: Do NOT use the existing dbt project directories. Create a fresh dbt project from scratch.

## Database Backend

This task supports both DuckDB and Snowflake. **Run `echo $DB_TYPE` in a shell BEFORE you write any code or spawn any subagents — the live env determines which backend the verifier runs against.** Do NOT assume a default from this prose. Reference dbt projects exist at `/app/dbt_models_duckdb/` and `/app/dbt_models_snowflake/` for inspection only. Write your dbt project at `/app/dbt_project` — outputs in the reference directories are not graded.

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
- Create a `profiles.yml` in the dbt project directory with profile name `dbt_project`
- Set `DBT_PROFILES_DIR` environment variable to the directory containing `profiles.yml`

### DuckDB Profile
Configure with `type: duckdb` and the database path from `$DUCKDB_PATH`.

### Snowflake Profile
Configure with `type: snowflake` using password authentication:
- Use the environment variables for account, user, password, database, schema, warehouse, and role

## Source Data

Use the `ORDERS.ORDERS` table which contains order records with columns including:
- `ORDERED_AT` - timestamp when order was placed
- `GRAND_TOTAL` - order total amount
- `STATUS` - order status (e.g., 'COMPLETED', 'SHIPPED', 'CANCELLED', 'RETURNED', 'FAILED')

## Requirements

1. Extract the date from `ORDERED_AT` timestamp
2. Exclude orders with STATUS IN ('CANCELLED', 'RETURNED', 'FAILED')
3. Group by order date and calculate:
   - Count of orders
   - Sum of revenue (rounded to 2 decimal places)
4. Sort results by order_date ascending

## Output Model

Create a model named `daily_order_summary` in schema `daily_analytics` with these columns:

| Column | Description |
|--------|-------------|
| order_date | The date (not timestamp) of orders |
| order_count | Number of orders placed that day |
| total_revenue | Sum of GRAND_TOTAL, rounded to 2 decimals |

## Technical Notes

- Configure the schema in `profiles.yml`, not in `dbt_project.yml`
- The model should be materialized as a table

## Guidelines

- The SQL syntax should work on both DuckDB and Snowflake (ANSI SQL compatible)
