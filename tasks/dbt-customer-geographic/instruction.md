# Customer Geographic Analysis

Build a dbt project that analyzes customer distribution and revenue by state.

## Files

- DuckDB: `/app/dbt_project` (create project here)
- Snowflake: `/app/dbt_project` (create project here)
- Target schema: `geographic_analytics`

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
Configure with `type: duckdb` and the database path from `$DUCKDB_PATH`. Use schema `geographic_analytics`.

### Snowflake Profile
Configure with `type: snowflake` using password authentication:
- Use the environment variables for account, user, password, database, schema, warehouse, and role

## Source Tables

The database contains the following tables:

- `CUSTOMER.CUSTOMER_ADDRESSES` - Customer address records. Explore the table to understand available columns including address_id, customer_id, state_province, and shipping flags.

- `ORDERS.ORDERS` - Order records. Explore the table to understand available columns including order_id, customer_id, status, and monetary amounts.

**Important:** Use the `CUSTOMER.CUSTOMER_ADDRESSES` table for address data (not RAW_SFDC or other schemas).

Only include orders with completed transaction statuses (COMPLETED, DELIVERED, SHIPPED).
Use only default shipping addresses (is_default_shipping = true).

## Requirements

Create a dbt project with staging and marts layers.

### Staging Models (models/staging/)

Create staging models:
- **stg_customer_addresses.sql** - Select address_id, customer_id, state_province. Filter to default shipping addresses.
- **stg_orders.sql** - Select order_id, customer_id, grand_total. Filter to completed/delivered/shipped statuses.

Define sources in sources.yml.

### Final Model (models/marts/)

Create **fct_state_customers.sql** that:
- Uses a LEFT JOIN from customer addresses to orders on customer_id (include all states that have default shipping addresses, even those without completed orders)
- Groups by state_province
- Counts distinct customers and orders
- Sums and averages revenue (use 0 for states with no orders)
- Round monetary values to 2 decimal places
- Materialize as a table
- The result should contain approximately 51 states/territories

### Required Output Columns

The final `fct_state_customers` table must have:
- state_province
- customer_count
- order_count
- total_revenue
- avg_order_value
- revenue_per_customer
- orders_per_customer

## Validation

- No NULL values allowed in any column
- Each state should appear exactly once
- All values must be non-negative

## Guidelines

- The SQL syntax should work on both DuckDB and Snowflake (ANSI SQL compatible)
- Ensure idempotent execution (multiple runs produce same results)
- Use explicit type casts where needed
- Handle NULL values appropriately
