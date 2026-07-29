# Multi-Warehouse Inventory Optimization

## Business Context

Your company operates 6 warehouses across different regions. The inventory team has noticed stockouts in some locations while other warehouses have excess inventory of the same products. They need a data model to identify which products need inventory rebalancing across warehouses to improve fulfillment efficiency.

## Files

- DuckDB: `/app/dbt_models_duckdb/models/marts/inventory/rpt_warehouse_rebalancing.sql`
- Snowflake: `/app/dbt_models_snowflake/models/marts/inventory/rpt_warehouse_rebalancing.sql`

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

## Data Sources

* **stg_inventory__inventory_levels**: variant_id, warehouse_id, QUANTITY_ON_HAND, QUANTITY_AVAILABLE, QUANTITY_RESERVED, UNIT_COST
* **stg_inventory__warehouses**: warehouse_id, IS_ACTIVE

* **int_sales__order_lines**: order_id, sku (use as variant_id), quantity_ordered
* **int_sales__orders_enriched**: ORDER_ID, status, ordered_at

## Requirements

Create a model with **one row per product variant** that analyzes inventory distribution across all warehouses.

### Base Metrics

For each variant, calculate:

- Total warehouses where the variant is stocked
- Total quantity on hand across all warehouses
- Total quantity available for sale
- Total quantity reserved for orders
- Average unit cost across warehouses
- Total inventory value (quantity x unit cost)
- Maximum stock level at any single warehouse
- Minimum stock level (excluding warehouses with zero stock)

### Demand Analysis

Analyze sales velocity using the last 90 days of **delivered** orders (use `MAX(ordered_at)` from the orders table as the reference date to ensure consistent results):

- Total units sold in the last 90 days
- Number of orders containing this variant
- Average daily sales rate (units per day)
- Projected days of stock remaining at current sales velocity

### Distribution Health

Calculate metrics that indicate whether inventory is well-distributed:

- **Stock concentration**: What proportion of total inventory sits in the warehouse with most stock?
- **Stock imbalance**: Calculate Coefficient of Variation (CV) of quantity across warehouses
- **Utilization**: What percentage of available inventory is already reserved?

### Priority Scoring

Create a `rebalancing_priority` score that identifies which variants need attention most urgently. The score should combine multiple risk factors:

- Stock imbalance accounts for 35% of the priority
- Stock concentration accounts for 25% of the priority
- Low inventory situations (less than 14 days remaining) add 20 points to urgency
- Limited warehouse coverage (fewer than 3 locations) adds 20 points to urgency

The final score should be scaled to 0-100 range

### Action Classification

Classify each variant into `rebalancing_action` using **waterfall logic** (check in order, assign first match):

1. **urgent_rebalance**

   - Days of stock remaining < 7
   - AND stock concentration ratio > 0.70
2. **high_priority**

   - Stock imbalance score > 0.80
   - OR (days of stock remaining < 14 AND stock concentration ratio > 0.60)
3. **rebalance_recommended**

   - Stock concentration ratio > 0.65
   - OR in the top 25% of priority scores (PERCENT_RANK() >= 0.75)
4. **monitor**

   - Days of stock remaining < 30
   - OR stocked in fewer than 2 warehouses
5. **well_distributed**

   - Stock concentration ratio < 0.40
   - AND stock imbalance score < 0.50
6. **Default**: All other cases -> `monitor`

## Expected Output Columns

Your model must include these columns:

- `variant_id`
- `total_warehouses_stocked`
- `total_quantity_on_hand`
- `total_quantity_available`
- `total_quantity_reserved`
- `avg_unit_cost`
- `total_inventory_value`
- `max_warehouse_stock`
- `min_warehouse_stock`
- `total_units_sold_90d`
- `total_orders_90d`
- `avg_daily_sales_velocity`
- `days_of_stock_remaining`
- `stock_concentration_ratio`
- `stock_imbalance_score`
- `utilization_rate`
- `rebalancing_priority`
- `rebalancing_action`

## Implementation Notes

### NULL Handling

- Use `COALESCE()` for all division operations to avoid inf/nan
- For `days_of_stock_remaining`: treat NULL as 999
- For `stock_imbalance_score` and `stock_concentration_ratio`: treat NULL as 0
- For `total_warehouses_stocked`: no NULL expected

### Window Functions

- Use `PERCENT_RANK()` over `rebalancing_priority` for the top 25% threshold in action classification

### Constraints

- Only include variants that have stock in at least one active warehouse
- Only include active warehouses (IS_ACTIVE = true)
- Handle cases where products have no recent sales (left join demand metrics)
- Ensure all division operations are safe (no infinity or NaN values)
- Classification should distinguish between different urgency levels

## Guidelines

- Do NOT modify upstream staging models
- Do NOT change model materialization
- Preserve all output columns
- The SQL syntax should work on both DuckDB and Snowflake (ANSI SQL compatible)
