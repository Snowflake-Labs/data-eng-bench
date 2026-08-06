# Product Performance Metrics

Build a product performance summary from sales data. Create a model called `fct_product_metrics` that aggregates key performance indicators for each product.

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

## Model Location

Create the model at `models/marts/product/fct_product_metrics.sql` in the dbt project directory:
- DuckDB: `/app/dbt_models_duckdb/models/marts/product/fct_product_metrics.sql`
- Snowflake: `/app/dbt_models_snowflake/models/marts/product/fct_product_metrics.sql`

## Requirements

Explore the staging models in the dbt project to find relevant tables for products, variants, orders, and order line items. You will need to understand the relationships between these tables and determine which columns to use.

The output model should provide a comprehensive product-level summary including identification fields, order counts, unit volumes, revenue, average pricing, and variant information.

**Order filtering**: Exclude orders with status `CANCELLED`, `RETURNED`, or `FAILED`. All other order statuses represent valid completed sales.

Output columns: `product_id`, `product_name`, `category`, `total_orders`, `units_sold`, `product_revenue`, `avg_unit_price`, `total_variants`

**Important**: `avg_unit_price` must be calculated as total revenue divided by total units sold (i.e., `product_revenue / units_sold` -- a weighted average, not a simple `AVG(unit_price)`).

All products should appear in the output, even those without any sales. Materialize as a table and sort by revenue descending.

## Guidelines

- Pay attention to the grain of your model -- joining across multiple dimensions can cause fan-out issues
