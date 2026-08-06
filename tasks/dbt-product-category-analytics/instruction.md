# Product Category Sales Analytics

Build a dbt project that analyzes product sales performance by category hierarchy.

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

## Environment

- dbt project location: `/app/dbt_project`

### DuckDB
- Output schema: `sales_analytics`

### Snowflake
- Output schema: `main`

## dbt Profile Setup

You must configure dbt to connect to the database:

### DuckDB Profile
- Create a `profiles.yml` with profile name `dbt_project`
- Configure with `type: duckdb` and the database path
- Set schema to `sales_analytics`

### Snowflake Profile
- Use the pre-built project at `/app/dbt_models_snowflake` as the base
- Create a symlink: `ln -sfn /app/dbt_models_snowflake /app/dbt_project`
- Configure `profiles.yml` in the project directory with profile name `retail_dw_master`
- Configure with `type: snowflake` using password authentication:
  - Use the environment variables for account, user, password, database, schema, warehouse, and role
  - Set schema to `main`

## Source Tables

The database contains the following tables across two schemas:

**ORDERS schema:**
- `ORDERS.ORDER_LINES` - Line items: order_line_id, order_id, product_id, quantity_ordered, unit_price, line_total, status
- `ORDERS.ORDERS` - Orders: order_id, customer_id, status, grand_total, ordered_at

**PRODUCT schema:**
- `PRODUCT.PRODUCTS` - Products: product_id, product_code, product_name, primary_category_id, cost_price
- `PRODUCT.PRODUCT_CATEGORIES` - Categories: category_id, category_code, category_name, parent_category_id, category_level

**Note on DuckDB**: In DuckDB, the orders table is located at `main.orders` (not `ORDERS.ORDERS`). Configure your dbt sources accordingly per backend.

**Note on cost_price**: The `cost_price` column in PRODUCTS may contain NULL values. Use `coalesce(cost_price, 0)` to handle missing costs so that downstream cost and profit calculations do not produce NULLs.

Valid order statuses for analysis: COMPLETED, DELIVERED, SHIPPED

## Requirements

Create a dbt project with the following structure:

### Staging Models (models/staging/)

Create staging models for:
- Order lines with cleaned data
- Products with trimmed strings
- Product categories
- Orders

Define appropriate sources for each schema. On Snowflake, both orders and order_lines are in the ORDERS schema. On DuckDB, order_lines is in the ORDERS schema but orders is in the main schema.

### Intermediate Model (models/intermediate/)

Create `int_product_sales.sql` that:
- Joins order lines with products and categories
- Only includes order lines from valid orders (completed, delivered, shipped)
- Calculates line-level revenue (from line_total) and cost (cost_price * quantity_ordered)
- Includes product and category information

### Final Model (models/marts/)

Create `fct_category_performance.sql` that aggregates to the category level:
- Total orders containing products from each category
- Total units sold
- Total revenue
- Total cost
- Gross profit (revenue minus cost)
- Profit margin percentage (profit divided by revenue, as decimal)
- Average order value for the category (total_revenue / total_orders)
- Round monetary values to 2 decimal places
- Materialize as a table

### Required Output Columns

The final `fct_category_performance` table must have:
- category_id
- category_name
- category_level
- total_orders
- total_units_sold
- total_revenue
- total_cost
- gross_profit
- profit_margin
- avg_order_value

## Validation

- No NULL values allowed in any column
- Each category should appear exactly once
- All monetary values must be non-negative
- Profit margin should be between 0 and 1

## Guidelines
- Use `trim()`, `coalesce()`, `cast()`, `round()`, `nullif()` which work on both backends
- For Snowflake, run dbt with `--select` specifying model names explicitly
