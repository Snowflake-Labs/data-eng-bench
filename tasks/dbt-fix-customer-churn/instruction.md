# Customer Activity Tracking

Build a dbt model called `fct_customer_activity` that tracks customer order history for churn analysis.

## Requirements

Create the model at:
- DuckDB: `/app/dbt_models_duckdb/models/marts/customer/fct_customer_activity.sql`
- Snowflake: `/app/dbt_models_snowflake/models/marts/customer/fct_customer_activity.sql`

The model should have these columns:

- `customer_id` - Customer identifier
- `email` - Customer email address
- `order_id` - Order identifier
- `order_date` - Order date (DATE type, not timestamp)
- `previous_order_date` - Previous order's date for this customer (DATE type). Use the DATE-typed order_date for window function calculations, not the raw timestamp.
- `days_since_last_order` - Days between consecutive orders (based on DATE values)
- `is_reactivated_order` - True if customers was inactive over 90 days

One row per order. Use `stg_orders__orders` as the source. Materialize as a table.

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

## Guidelines

- The SQL must work on both DuckDB and Snowflake. Use Jinja conditionals where syntax differs.
- Ensure deterministic ordering when multiple orders share the same date
