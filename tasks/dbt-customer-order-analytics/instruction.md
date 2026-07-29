# Customer Order Analytics with Tiering

Build a dbt project that creates customer order analytics with tiering based on purchase history.

## Files

- DuckDB: `/app/dbt_project` (create project here)
- Snowflake: `/app/dbt_project` (create project here)
- Target schema: `customer_analytics`
- Reference transforms: `/app/dbt_transforms` (read-only, for reference)

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
- Create a `profiles.yml` in the dbt project directory with profile name `retail_dw_master`
- Set `DBT_PROFILES_DIR` environment variable to the directory containing `profiles.yml`

### DuckDB Profile
Configure with `type: duckdb` and the database path from `$DUCKDB_PATH`.

### Snowflake Profile
Configure with `type: snowflake` using password authentication:
- Use the environment variables for account, user, password, database, schema, warehouse, and role

## Source Tables

The database contains two relevant tables:

- **`ORDERS.CUSTOMERS`** - Customer records. Explore the table to understand available columns including customer identifiers, names, email, and status.
- **`ORDERS.ORDERS`** - Order records. Explore the table to understand available columns including order identifiers, customer linkage, status, monetary values, and timestamps.

Order status values include: COMPLETED, DELIVERED, PROCESSING, PENDING, CANCELLED, RETURNED, FAILED

## Requirements

Create a dbt project with staging, intermediate, and marts layers.

### Staging Models (models/staging/)

Create staging models for customers and orders. Clean string fields by trimming whitespace. Normalize order status to uppercase. Define appropriate sources.

### Intermediate Model (models/intermediate/)

**int_customer_order_metrics.sql** - Calculate per-customer metrics:
- Only count valid orders (exclude CANCELLED, RETURNED, and FAILED orders)
- Calculate: order count, total spend, average order value
- Track first and last order dates
- Calculate days since last order using 2024-12-01 as the reference date
- Round monetary values to 2 decimal places

### Final Model (models/marts/)

Create **dim_customer_tiers.sql** that:
- Joins customer information with order metrics
- Only includes customers who have made at least one valid order
- Concatenates first and last name into customer_name
- Assigns customer tier based on order frequency:
  - **VIP**: 5 or more orders
  - **Regular**: 3 to 4 orders
  - **New**: 1 to 2 orders
- Materialize as a table

### Required Output Columns

The final `dim_customer_tiers` table must have these columns:
- customer_id
- customer_name
- email
- order_count
- total_spend
- avg_order_value
- first_order_date
- last_order_date
- days_since_last_order
- customer_tier

## Validation

- No NULL values allowed in any column
- Each customer should appear exactly once
- All monetary values must be positive
- Customer tier must be one of: VIP, Regular, New

## Guidelines

- The SQL syntax should work on both DuckDB and Snowflake (ANSI SQL compatible)
- Ensure idempotent execution (multiple runs produce same results)
- Use explicit type casts where needed
- Handle NULL values appropriately
