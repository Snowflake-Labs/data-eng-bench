# Advanced Inventory Stockout Risk Analytics Mart

Build a dbt project that calculates comprehensive near-term stockout risk for each SKU at each warehouse location using advanced analytics including multi-period sales velocity, trend analysis, lead time considerations, safety stock calculations, and statistical measures.

## Files

- DuckDB: `/app/dbt_project` (create project here)
- Snowflake: `/app/dbt_project` (create project here)
- Target schema: `analytics`
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
- Create a `profiles.yml` in the dbt project directory with profile name `inventory_stockout_risk`
- Set `DBT_PROFILES_DIR` environment variable to the directory containing `profiles.yml`

### DuckDB Profile
Configure with `type: duckdb` and the database path from `$DUCKDB_PATH`.

### Snowflake Profile
Configure with `type: snowflake` using password authentication:
- Use the environment variables for account, user, password, database, schema, warehouse, and role

## Source Data

The database contains the following source tables:

1. **`INVENTORY.INVENTORY_LEVELS`** - Current inventory levels by variant and location
   - Key columns: `variant_id`, `warehouse_id`, `quantity_on_hand`, `quantity_available`, `quantity_incoming`

2. **`ORDERS.ORDER_LINES`** - Historical order line items
   - Key columns: `order_id`, `variant_id`, `quantity_ordered`, `unit_price`

3. **`ORDERS.ORDERS`** - Order header information
   - Key columns: `order_id`, `ordered_at`, `status`

4. **`PRODUCT.PRODUCT_VARIANTS`** - Product variant master data
   - Key columns: `variant_id`, `product_id`, `sku`, `variant_name`

5. **`PRODUCT.PRODUCTS`** - Product master data
   - Key columns: `product_id`, `product_name`, `category_id`

6. **`INVENTORY.WAREHOUSES`** - Warehouse master data
   - Key columns: `warehouse_id`, `warehouse_name`, `warehouse_code`

7. **`INVENTORY.REORDER_RULES`** - Reorder configuration rules by variant and warehouse
   - Key columns: `variant_id`, `warehouse_id`, `lead_time_days`, `SAFETY_STOCK` (use as safety_stock_days)
   - Note: Some variants may not have reorder rules (use defaults if missing)

8. **`PROCUREMENT.PURCHASE_ORDERS`** - Historical purchase orders for lead time analysis
   - Key columns: `po_id`, `warehouse_id`, `ordered_at`, `expected_date`, `status`
   - Note: Use this to calculate actual lead times when REORDER_RULES.lead_time_days is NULL
   - Related tables: `PROCUREMENT.PURCHASE_ORDER_LINES` (contains `variant_id` per line item, linked via `po_id`) and `PROCUREMENT.PURCHASE_ORDER_RECEIPTS` (contains `received_at` per receipt, linked via `po_id`)

## Project Setup

1. Create a dbt project at `/app/dbt_project`
2. Configure `profiles.yml` to connect to the database with schema `analytics`
3. Do not add `+schema` in `dbt_project.yml` (only set schema in profiles.yml)

## Required Models

### 1. Staging: `stg_orders_clean.sql`

Location: `models/staging/stg_orders_clean.sql`

**Purpose**: Clean and normalize order data

**Requirements**:
- Filter out orders where `status = 'CANCELLED'`
- Filter out orders where `ordered_at` is NULL
- Cast `ordered_at` to TIMESTAMP as `order_ts`
- Extract DATE from `ordered_at` as `order_date`
- Join with `ORDERS.ORDER_LINES` to get line-level details
- Filter out order lines where `quantity_ordered <= 0`
- Preserve all valid order and line attributes

**Output columns**:
- `order_id` (VARCHAR)
- `order_ts` (TIMESTAMP)
- `order_date` (DATE)
- `variant_id` (VARCHAR)
- `quantity_ordered` (DECIMAL)
- `unit_price` (DECIMAL)

### 2. Intermediate: `int_sales_velocity.sql`

Location: `models/intermediate/int_sales_velocity.sql`

**Purpose**: Calculate multi-period sales velocity metrics with statistical measures

**Requirements**:
- One row per `variant_id` (not per warehouse)
- Use `MAX(order_date)` from the orders data as the reference date for all time-based calculations (do NOT use `CURRENT_DATE`)
- Calculate average daily sales for multiple periods (relative to the reference date):
  - `avg_daily_sales_7d`: Average over last 7 days
  - `avg_daily_sales_30d`: Average over last 30 days
  - `avg_daily_sales_90d`: Average over last 90 days
- Calculate sales velocity ratio: `avg_daily_sales_7d / NULLIF(avg_daily_sales_30d, 0)`
- Calculate trend direction:
  - `'ACCELERATING'` when `sales_velocity_ratio > 1.2`
  - `'STABLE'` when `sales_velocity_ratio >= 0.8 AND sales_velocity_ratio <= 1.2`
  - `'DECELERATING'` when `sales_velocity_ratio < 0.8`
  - `NULL` when `avg_daily_sales_30d` is NULL or 0
- Calculate statistical measures:
  - `sales_volatility_30d`: Standard deviation of daily sales over last 30 days (NULL if < 2 data points)
  - `sales_volatility_90d`: Standard deviation of daily sales over last 90 days (NULL if < 2 data points)
  - `p25_daily_sales_30d`: 25th percentile of daily sales over last 30 days
  - `p75_daily_sales_30d`: 75th percentile of daily sales over last 30 days
  - `median_daily_sales_30d`: Median of daily sales over last 30 days
- Use window functions and aggregations efficiently

**Output columns**:
- `variant_id` (VARCHAR)
- `avg_daily_sales_7d` (DOUBLE)
- `avg_daily_sales_30d` (DOUBLE)
- `avg_daily_sales_90d` (DOUBLE)
- `sales_velocity_ratio` (DOUBLE)
- `trend_direction` (VARCHAR)
- `sales_volatility_30d` (DOUBLE)
- `sales_volatility_90d` (DOUBLE)
- `p25_daily_sales_30d` (DOUBLE)
- `p75_daily_sales_30d` (DOUBLE)
- `median_daily_sales_30d` (DOUBLE)

### 3. Intermediate: `int_lead_time_calculations.sql`

Location: `models/intermediate/int_lead_time_calculations.sql`

**Purpose**: Calculate effective lead times with fallback logic

**Requirements**:
- One row per `(variant_id, warehouse_id)` combination
- Lead time priority:
  1. `REORDER_RULES.lead_time_days` if available
  2. Average from `PURCHASE_ORDERS` (status `'RECEIVED'` or `'COMPLETED'`) in last 180 days: `AVG(DATEDIFF('day', ordered_at, COALESCE(received_at, expected_date)))`
  3. Default: 14 days
- Calculate lead time statistics:
  - `lead_time_days`: Effective lead time (clamped between 1 and 365)
  - `lead_time_std_dev`: Standard deviation of lead times from purchase orders (NULL if < 2 data points)
  - `lead_time_min`: Minimum lead time from purchase orders (NULL if no data)
  - `lead_time_max`: Maximum lead time from purchase orders (NULL if no data)
- Safety stock days: from `REORDER_RULES.SAFETY_STOCK` or default 7
- Reorder point multiplier: default 1.5 (not in REORDER_RULES table)

**Output columns**:
- `variant_id` (VARCHAR)
- `warehouse_id` (VARCHAR)
- `lead_time_days` (DOUBLE)
- `lead_time_std_dev` (DOUBLE)
- `lead_time_min` (DOUBLE)
- `lead_time_max` (DOUBLE)
- `safety_stock_days` (DOUBLE)
- `reorder_point_multiplier` (DOUBLE)

### 4. Mart: `fct_stockout_risk.sql`

Location: `models/marts/operations/fct_stockout_risk.sql`

**Purpose**: Final stockout risk mart with comprehensive risk analysis

**Requirements**:
- Grain: one row per `(warehouse_id, variant_id)` combination
- Join inventory levels with sales velocity, lead times, and product/warehouse dimensions
- Calculate safety stock and reorder points:
  - `safety_stock_quantity = safety_stock_days * avg_daily_sales_30d` (NULL if no sales)
  - `reorder_point = (lead_time_days * avg_daily_sales_30d * reorder_point_multiplier) + safety_stock_quantity` (NULL if no sales)
- Calculate days until metrics:
  - `days_until_stockout = quantity_available / NULLIF(avg_daily_sales_30d, 0)`
  - `days_until_reorder_point = (quantity_available - reorder_point) / NULLIF(avg_daily_sales_30d, 0)` when `quantity_available < reorder_point`, else `NULL`
- Advanced stockout risk classification (considering volatility and lead time uncertainty):
  - `'NO_RISK'`: `avg_daily_sales_30d IS NULL OR avg_daily_sales_30d = 0`
  - `'CRITICAL'`:
    - `quantity_available <= safety_stock_quantity` OR
    - (`days_until_stockout IS NOT NULL AND days_until_stockout <= lead_time_days AND trend_direction IN ('ACCELERATING', 'STABLE')`) OR
    - (`days_until_stockout IS NOT NULL AND days_until_stockout <= (lead_time_days + COALESCE(lead_time_std_dev, 0)) AND sales_volatility_30d IS NOT NULL AND sales_volatility_30d > (avg_daily_sales_30d * 0.3)`)
  - `'HIGH'`:
    - `quantity_available > safety_stock_quantity AND quantity_available <= reorder_point` OR
    - (`days_until_stockout IS NOT NULL AND days_until_stockout <= (lead_time_days + safety_stock_days) AND trend_direction = 'ACCELERATING'`) OR
    - (`days_until_stockout IS NOT NULL AND days_until_stockout <= (lead_time_days + COALESCE(lead_time_std_dev, 0) + safety_stock_days) AND sales_volatility_30d IS NOT NULL AND sales_volatility_30d > (avg_daily_sales_30d * 0.2)`)
  - `'MEDIUM'`:
    - `quantity_available > reorder_point AND quantity_available <= (reorder_point * 1.5)` OR
    - (`days_until_stockout IS NOT NULL AND days_until_stockout <= (lead_time_days * 2) AND trend_direction IN ('ACCELERATING', 'STABLE')`)
  - `'LOW'`: otherwise
- Recommended action mapping:
  - `'CRITICAL'` -> `'URGENT_REORDER'`
  - `'HIGH'` -> `'REORDER_NOW'`
  - `'MEDIUM'` -> `'PLAN_REORDER'`
  - `'LOW'` -> `'MONITOR'`
  - `'NO_RISK'` -> `'NO_ACTION'`

**Output columns** (in order):
- `warehouse_name` (VARCHAR)
- `product_name` (VARCHAR)
- `sku` (VARCHAR)
- `quantity_on_hand` (DECIMAL)
- `quantity_available` (DECIMAL)
- `quantity_incoming` (DECIMAL)
- `avg_daily_sales_7d` (DOUBLE)
- `avg_daily_sales_30d` (DOUBLE)
- `avg_daily_sales_90d` (DOUBLE)
- `sales_velocity_ratio` (DOUBLE)
- `trend_direction` (VARCHAR)
- `sales_volatility_30d` (DOUBLE)
- `sales_volatility_90d` (DOUBLE)
- `p25_daily_sales_30d` (DOUBLE)
- `p75_daily_sales_30d` (DOUBLE)
- `median_daily_sales_30d` (DOUBLE)
- `lead_time_days` (DOUBLE)
- `lead_time_std_dev` (DOUBLE)
- `lead_time_min` (DOUBLE)
- `lead_time_max` (DOUBLE)
- `safety_stock_days` (DOUBLE)
- `safety_stock_quantity` (DOUBLE)
- `reorder_point_multiplier` (DOUBLE)
- `reorder_point` (DOUBLE)
- `days_until_stockout` (DOUBLE)
- `days_until_reorder_point` (DOUBLE)
- `stockout_risk` (VARCHAR)
- `recommended_action` (VARCHAR)

## Business Rules

1. **Sales Calculations**: Use actual calendar days in period (7, 30, 90) for averaging
2. **Volatility Calculation**: Use sample standard deviation (divide by n-1, not n)
3. **Percentile Calculation**: Use `PERCENTILE_CONT` (continuous) for percentile calculations
4. **Lead Time Clamping**: Lead times must be between 1 and 365 days (use GREATEST/LEAST)
5. **NULL Handling**:
   - Sales metrics should be NULL (not 0) when there are no sales in a period
   - Volatility should be NULL when there are < 2 data points
   - Days until metrics should be NULL when sales are 0 or NULL
6. **Grain Uniqueness**: Exactly one row per `(warehouse_id, variant_id)` combination
7. **Reconciliation**: Total sales quantities should match source order lines within 0.1% relative error

## Quality + Invariants (enforced)

- No NULLs in `warehouse_name`, `product_name`, `sku` (use COALESCE with defaults if needed)
- `avg_daily_sales_*` should be NULL or >= 0 (never negative)
- `sales_velocity_ratio` should be NULL when `avg_daily_sales_30d` is 0 or NULL
- `sales_volatility_*` should be NULL or >= 0
- `lead_time_days` must be between 1 and 365
- `safety_stock_days` and `reorder_point_multiplier` must be > 0
- `days_until_stockout` should be NULL when `avg_daily_sales_30d` is 0 or NULL
- `days_until_reorder_point` should be NULL when `quantity_available >= reorder_point` or `avg_daily_sales_30d` is 0 or NULL
- `p25_daily_sales_30d <= median_daily_sales_30d <= p75_daily_sales_30d` (when all are non-NULL)
- Grain uniqueness: exactly one row per `(warehouse_id, variant_id)` combination
- Idempotent and deterministic: reruns should not change totals

## Guidelines

- Ensure idempotent execution (multiple runs produce same results)
- Use explicit type casts where needed
- Handle NULL values appropriately
- Avoid cartesian products or inefficient joins
- Use window functions where appropriate for statistical calculations
- Materialize intermediate models as tables for performance
