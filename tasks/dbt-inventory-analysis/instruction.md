# Warehouse Inventory Analysis

Build a dbt project that produces a warehouse-level inventory summary with quantities, values, and cost metrics.

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

The warehouse contains inventory and warehouse reference data in the INVENTORY schema. Explore the available tables to discover relevant columns for quantities, costs, and warehouse attributes. You will need to understand what columns are available and how the tables relate to each other before writing your models.

Only include records where the on-hand quantity is greater than zero.

## Requirements

Create a dbt project with staging and marts layers.

### dbt Project Location
- DuckDB: `/app/dbt_project`
- Snowflake: `/app/dbt_project`

### Output Schema
- `inventory_analytics`

### Staging Models (models/staging/)

Create staging models that clean and standardize the source data:
- Trim string fields and use COALESCE for numeric fields
- Define sources in sources.yml

### Final Model (models/marts/)

Create **fct_warehouse_inventory.sql** that produces a warehouse-level inventory summary. For each warehouse, compute:

1. **Basic identification**: warehouse ID, name, type, and location (city, state/province)
2. **Total quantity**: the sum of all on-hand quantities across all products in the warehouse
3. **Inventory value**: the total monetary value of all inventory (quantity times per-unit cost, summed across products)
4. **Distinct product count**: the number of unique product variants stocked in the warehouse
5. **Weighted average unit cost (`avg_unit_cost`)**: the inventory-value-weighted average cost per unit. This is NOT a simple arithmetic average of unit costs -- it must account for the fact that a product with 1000 units matters more than one with 2 units. Specifically: total inventory value divided by total quantity.
6. **Max single item value**: the highest total-value line item in the warehouse (i.e., for a single product, its quantity times its unit cost -- find the maximum of these across all products)
7. **Inventory concentration**: the fraction of total warehouse inventory value held by the single most valuable product line. Express as a ratio between 0 and 1, rounded to 4 decimal places. For example, if warehouse total value is $1,000,000 and the most valuable single product contributes $250,000, concentration = 0.2500.

Round all monetary values to 2 decimal places. Materialize as a table.

## Validation

- No NULL values allowed in any column
- Each warehouse should appear exactly once
- All quantity and value columns must be non-negative
- Inventory concentration must be between 0 and 1 (exclusive of 0, inclusive of 1)

## Guidelines

- Do NOT set schema in dbt_project.yml
- The SQL syntax should work on both DuckDB and Snowflake (ANSI SQL compatible)
