# Product Cumulative Sales Tracking

Build a dbt model called `fct_inventory_balance` that tracks cumulative sales for products over time.

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

## Requirements

Create `models/marts/inventory/fct_inventory_balance.sql` with these columns:

- DuckDB: `/app/dbt_models_duckdb/models/marts/inventory/fct_inventory_balance.sql`
- Snowflake: `/app/dbt_models_snowflake/models/marts/inventory/fct_inventory_balance.sql`

Columns:

- `product_id` - Product identifier from products table
- `product_name` - Product name from products table
- `order_date` - Order date (cast ORDERED_AT column to DATE type from orders table)
- `order_line_id` - Order line identifier
- `units_sold` - Quantity from order lines (use `quantity_ordered`)
- `revenue` - Line total from order lines
- `cumulative_units_sold` - Running total of units per product up to and including current date
- `cumulative_revenue` - Running total of revenue per product up to and including current date
- `prev_day_cumulative_revenue` - The maximum cumulative revenue from the PREVIOUS calendar date for this product (NULL for first date). All rows on the same date should show the same prev_day value.
- `daily_change` - Difference between current cumulative and previous day's cumulative revenue
- `rank_in_day` - Ranking of order lines within same product and date, ordered by order_line_id ascending
- `days_since_last_sale` - Number of days between current order_date and the previous DISTINCT order_date for this product (NULL for first date). Use LAG over distinct (product_id, order_date) pairs, not over raw rows.
- `running_avg_revenue_per_line` - Cumulative revenue divided by cumulative units sold (handle division by zero)
- `cumulative_percentile` - PERCENT_RANK of the product's current cumulative revenue compared to ALL products' current cumulative revenue on the same date

**Data Filtering:** Only include order lines where the order status is NOT 'cancelled' or 'refunded'. Check the `status` column in the orders table.

**Join Path:** Use staging tables: `stg_orders__order_lines`, `stg_orders__orders`, `stg_product__product_variants`, `stg_product__products`. Join order lines to orders on `order_id`, then join to product variants on `variant_id` from order lines, then join to products on `product_id` from product variants.

**Window Functions:**
- For cumulative columns, use `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` to ensure same-date values match
- For `prev_day_cumulative_revenue`, calculate the maximum cumulative from the previous date using a self-join or window function
- For `rank_in_day`, use ROW_NUMBER partitioned by product and date, ordered by order_line_id
- For `days_since_last_sale`, use LAG on order_date then calculate DATEDIFF
- For `cumulative_percentile`, use PERCENT_RANK partitioned by order_date, ordered by cumulative_revenue

**Schema Configuration:** Also create `models/marts/inventory/schema.yml` that defines a test ensuring `cumulative_revenue` is never negative.

Materialize as a table.

## Data Sources

The model uses these staging tables (explore each to understand available columns):
- **stg_orders__order_lines** - Contains order line details including quantities, amounts, and identifiers
- **stg_orders__orders** - Contains order header information including timestamps and status
- **stg_product__product_variants** - Maps variants to products
- **stg_product__products** - Contains product information
