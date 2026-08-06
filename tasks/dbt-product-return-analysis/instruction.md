# Build Product Return Analysis Model

## Overview

Create a new dbt model that analyzes product return patterns to identify high-risk products and understand return behavior.

## Files
- DuckDB: `/app/dbt_models_duckdb/models/marts/product/rpt_product_returns.sql`
- Snowflake: `/app/dbt_models_snowflake/models/marts/product/rpt_product_returns.sql`

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

### Data Sources

Use these tables:

- `int_sales__orders_enriched` - Orders with status info (exclude CANCELLED orders)
- `int_sales__order_lines` - Order line items (use `quantity_ordered` for quantity)
- `stg_orders__returns` - Return records (use `requested_at` for return date)
- `stg_orders__return_lines` - Return line items (links to order_line_id)
- `stg_product__products` - Product master data (**INNER JOIN on `product_id`** — products not present in this catalog must be excluded)
- `stg_product__product_categories` - Product categories (join via `primary_category_id`)

### Product Set

The report must include **every product that has at least one non-cancelled order line**, subject to these four rules applied together:

1. **Non-cancelled sales only**: join `int_sales__order_lines` to `int_sales__orders_enriched` on `order_id` and filter `status != 'CANCELLED'`. Only non-cancelled order lines count toward sales and determine whether a product is in scope.
2. **Catalog membership**: INNER JOIN `stg_product__products` on `product_id` — products without a catalog entry are excluded (already noted in Data Sources above).
3. **Non-null product_id**: rows in `int_sales__order_lines` where `product_id IS NULL` must be excluded.
4. **Zero-return products included**: use a LEFT JOIN for returns (`stg_orders__return_lines` / `stg_orders__returns`). A product that has sales but zero returns must still appear in the output with `total_returned = 0` and `return_rate = 0`. Do **not** INNER JOIN returns — that would silently drop zero-return products from the report.

### Metrics to Calculate (per product)

1. **total_sold** - Total quantity sold (sum of `quantity_ordered`)
2. **total_orders** - Count of distinct orders containing this product
3. **total_returned** - Total quantity returned (sum of `quantity_returned`)
4. **total_return_requests** - Count of distinct return lines
5. **return_rate** - Percentage of sold items returned (returned / sold). **Note: return_rate can exceed 1.0** — return records come from `ORDERS.RETURN_LINES` (linked via `order_line_id`) and may include returns from prior periods not reflected in the current period's sold quantity.
6. **avg_days_to_return** - Average days between order date and return request date
7. **revenue** - Total revenue from this product (sum of `line_total`)
8. **lost_revenue** - Revenue lost to returns (revenue * return_rate)

### Classification Column

Add a `return_risk_tier` column using waterfall logic (check worst tier first):

- `'high_risk'`: return_rate is at or above the 85th percentile (using PERCENT_RANK >= 0.85) AND total_returned > 5
- `'moderate_risk'`: return_rate is at or above the 60th percentile (PERCENT_RANK >= 0.60) OR lost_revenue > 1000 (but does NOT meet high_risk criteria)
- `'minimal_risk'`: Products with total_returned = 0 (no returns at all)
- `'low_risk'`: All remaining products

## Expected Output

| Column                | Type    | Description             |
| --------------------- | ------- | ----------------------- |
| product_id            | varchar | Product identifier      |
| product_name          | varchar | Product name            |
| category              | varchar | Product category name   |
| total_sold            | integer | Units sold              |
| total_orders          | integer | Order count             |
| total_returned        | integer | Units returned          |
| total_return_requests | integer | Return line count       |
| return_rate           | decimal | Return rate (total_returned/total_sold, may exceed 1) |
| avg_days_to_return    | decimal | Avg days to return      |
| revenue               | decimal | Total revenue           |
| lost_revenue          | decimal | Revenue lost to returns |
| return_risk_tier      | varchar | Risk classification     |

## Validation

- Model compiles and runs successfully
- **Product set**: the output must contain every product with at least one non-cancelled order line that also exists in `stg_product__products` and has a non-null `product_id`. Products without a catalog entry are excluded. Products with sales but zero returns must be present (return metrics = 0).
- Only non-cancelled order lines (join to `int_sales__orders_enriched`, filter `status != 'CANCELLED'`) contribute to `total_sold`, `total_orders`, and the product set.
- Returns are LEFT-JOINed — the product set is driven by sales, not by returns.
- No invalid values (infinity, NaN) in calculations
- `return_risk_tier` must have correct tier assignments based on percentile thresholds
- Use `percent_rank()` or ntile() for efficient calculation

## Guidelines

- Do NOT modify upstream staging models
- Do NOT change model materialization
- Preserve all output columns
