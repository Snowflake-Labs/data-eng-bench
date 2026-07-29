# FIFO Inventory Valuation and Cost Analysis

## Background

Your company uses the First-In-First-Out (FIFO) method for inventory costing. This task requires implementing a comprehensive FIFO inventory system with cost variance analysis, inventory aging, and turnover metrics using **pure SQL** dbt models.

## Database Backend

This task supports two database backends, controlled by the `DB_TYPE` environment variable:

- **DuckDB** (`DB_TYPE=duckdb`): Local DuckDB database at path `$DUCKDB_PATH` (default: `/app/database/retail.duckdb`)
- **Snowflake** (`DB_TYPE=snowflake`): Snowflake cloud database. Connection details are provided via environment variables:
  - `SNOWFLAKE_ACCOUNT`, `SNOWFLAKE_USER`, `SNOWFLAKE_PASSWORD`
  - `SNOWFLAKE_DATABASE`, `SNOWFLAKE_SCHEMA`, `SNOWFLAKE_WAREHOUSE`, `SNOWFLAKE_ROLE`
  - The Snowflake database is a clone created for this task and will be cleaned up afterward.

## dbt Profile Setup

- **Profile name**: `retail_dw_master`
- **DuckDB profile**:
  - `type: duckdb`
  - `path:` set to `$DUCKDB_PATH`
- **Snowflake profile**:
  - `type: snowflake`
  - `account`, `user`, `database`, `schema`, `warehouse`, `role` from environment variables

## dbt Project

- **DuckDB project dir**: `/app/dbt_models_duckdb`
- **Snowflake project dir**: `/app/dbt_models_snowflake`

Run `dbt deps` before running models.

## Guidelines

- The SQL syntax should work on both DuckDB and Snowflake (ANSI SQL compatible).
- Use `DATEDIFF('day', start_date, end_date)` for date differences (works on both backends).
- Use `TO_VARCHAR(date, 'YYYY-MM')` for date formatting (works on both backends).
- Avoid DuckDB-specific functions like `strftime`, `date_diff`, `CROSS JOIN LATERAL`.
- Use `CAST(x AS DOUBLE)` for float conversions.
- Use `CEIL` (not `CEILING`) for ceiling function.
- For Snowflake, override `macros/utils/generate_schema_name.sql` to route all models to the default schema.

## Task

Create a multi-model dbt solution for FIFO inventory analysis. All models should be in `models/marts/inventory/` and use schema `inventory_analytics`.

**Note**: The dbt project prefixes custom schemas with `main_`, so `inventory_analytics` becomes `main_inventory_analytics` in the database. For Snowflake, override the `generate_schema_name` macro to route all models to the default `main` schema.

## Required Models (7 total)

### 1. Staging: `stg_fifo_transactions.sql`

Prepare inventory transactions for FIFO processing. Only RECEIPT and PICK transactions are relevant for FIFO costing.

**Output columns**:
| Column | Description |
|--------|-------------|
| transaction_id | Original TRANSACTION_ID |
| warehouse_id | Warehouse identifier |
| variant_id | Product variant identifier |
| transaction_type | 'RECEIPT' or 'PICK' |
| transaction_timestamp | TRANSACTION_TIMESTAMP |
| transaction_date | TRANSACTION_DATE |
| quantity | ABS(QUANTITY) - always positive |
| unit_cost | UNIT_COST (0 if NULL) |
| row_num | ROW_NUMBER() partitioned by warehouse_id, variant_id, transaction_type ordered by timestamp, transaction_id |

### 2. Intermediate: `int_receipt_layers.sql`

Create receipt layer tracking with cumulative quantities.

**Output columns**:
| Column | Description |
|--------|-------------|
| receipt_id | TRANSACTION_ID of the receipt |
| warehouse_id | Warehouse identifier |
| variant_id | Product variant identifier |
| receipt_timestamp | TRANSACTION_TIMESTAMP |
| receipt_date | TRANSACTION_DATE |
| receipt_qty | Original quantity received |
| unit_cost | Cost per unit |
| cumulative_qty_before | Sum of prior receipt quantities (0 for first) |
| cumulative_qty_after | cumulative_qty_before + receipt_qty |
| days_since_receipt | Days between receipt_date and current_date (use '2025-12-31' as reference) |
| age_bucket | 'Current (0-30)', 'Aging (31-90)', 'Slow (91-180)', 'Obsolete (180+)' |

**Requirements**:
- Order by `TRANSACTION_TIMESTAMP` ASC, then `TRANSACTION_ID` ASC (deterministic tie-breaking)
- cumulative_qty_before for the first receipt per warehouse-variant must be exactly 0

### 3. Intermediate: `int_pick_consumption.sql`

Track cumulative pick consumption per warehouse-variant.

**Output columns**:
| Column | Description |
|--------|-------------|
| pick_id | TRANSACTION_ID of the pick |
| warehouse_id | Warehouse identifier |
| variant_id | Product variant identifier |
| pick_timestamp | TRANSACTION_TIMESTAMP |
| pick_date | TRANSACTION_DATE |
| pick_qty | Quantity picked |
| consumption_start | Cumulative consumption before this pick |
| consumption_end | consumption_start + pick_qty |

### 4. Intermediate: `int_fifo_allocation.sql`

Allocate each pick to receipt layers using FIFO range-overlap logic.

**Output columns**:
| Column | Description |
|--------|-------------|
| pick_id | TRANSACTION_ID of the pick |
| pick_timestamp | TRANSACTION_TIMESTAMP |
| pick_date | TRANSACTION_DATE |
| warehouse_id | Warehouse identifier |
| variant_id | Product variant identifier |
| receipt_id | TRANSACTION_ID of consumed receipt |
| receipt_unit_cost | Unit cost from receipt |
| allocated_qty | Quantity from this receipt for this pick |
| allocation_cost | allocated_qty * receipt_unit_cost |
| pick_total_qty | Total quantity of the pick |
| total_available_before_pick | Total receipts before pick timestamp |
| is_fully_fulfilled | TRUE if pick <= total_available_before_pick |

**FIFO Logic**:
1. Calculate cumulative receipt ranges [cumulative_before, cumulative_after] per warehouse-variant
2. Calculate cumulative pick consumption ranges [consumption_start, consumption_end]
3. Join where: receipt occurred before pick AND ranges overlap
4. Allocated quantity = LEAST(receipt_end, pick_consumption_end) - GREATEST(receipt_start, pick_consumption_start)

**Critical**: Receipts must be consumed in strict chronological order. No pick should consume from receipt B before exhausting available quantity from earlier receipt A.

### 5. Mart: `fifo_cogs_monthly.sql`

Monthly COGS aggregation with cost analysis.

**Output columns**:
| Column | Description |
|--------|-------------|
| year_month | Format YYYY-MM |
| category_name | Product category ('Uncategorized' if NULL) |
| warehouse_id | Warehouse identifier |
| total_picks | Count of distinct pick transactions |
| total_units_requested | Sum of pick quantities |
| total_units_fulfilled | Sum of allocated quantities |
| total_units_unfulfilled | total_units_requested - total_units_fulfilled |
| total_cogs | Sum of allocation costs |
| avg_fifo_unit_cost | total_cogs / total_units_fulfilled (NULL if 0) |
| fulfillment_rate | total_units_fulfilled / total_units_requested (0 if no requests) |
| pick_count_fully_fulfilled | Count of picks where is_fully_fulfilled = TRUE |
| pick_count_partial | Count of picks where is_fully_fulfilled = FALSE |

**Requirements**:
- Round monetary values to 2 decimals
- Round rates to 4 decimals
- Sort by year_month, category_name, warehouse_id

### 6. Mart: `ending_inventory_valuation.sql`

Remaining inventory with aging analysis.

**Output columns**:
| Column | Description |
|--------|-------------|
| warehouse_id | Warehouse identifier |
| variant_id | Product variant identifier |
| category_name | Product category |
| sku | Product SKU from PRODUCT_VARIANTS |
| total_units_remaining | Remaining quantity across all layers |
| total_value | Sum of (remaining_qty * unit_cost) per layer |
| weighted_avg_cost | total_value / total_units_remaining |
| layer_count | Number of receipt layers with remaining qty |
| oldest_layer_date | Earliest receipt date with remaining inventory |
| newest_layer_date | Latest receipt date with remaining inventory |
| avg_days_in_inventory | Average days since receipt weighted by remaining qty |
| current_units | Units in 'Current (0-30)' bucket |
| aging_units | Units in 'Aging (31-90)' bucket |
| slow_units | Units in 'Slow (91-180)' bucket |
| obsolete_units | Units in 'Obsolete (180+)' bucket |
| obsolete_value | Value of obsolete inventory |

**Requirements**:
- Only include rows where total_units_remaining > 0
- Sort by warehouse_id, category_name, sku

### 7. Mart: `inventory_turnover_analysis.sql`

Inventory turnover and efficiency metrics.

**Output columns**:
| Column | Description |
|--------|-------------|
| warehouse_id | Warehouse identifier |
| category_name | Product category |
| total_receipts_qty | Sum of all receipt quantities |
| total_picks_qty | Sum of all pick quantities |
| total_cogs | Sum of COGS from picks |
| ending_inventory_qty | Current remaining inventory |
| ending_inventory_value | Current inventory value |
| avg_inventory_value | (total_receipts_value + ending_inventory_value) / 2 |
| inventory_turnover_ratio | total_cogs / avg_inventory_value (NULL if 0) |
| days_inventory_outstanding | 365 / inventory_turnover_ratio (NULL if 0) |
| fulfillment_efficiency | total_picks_qty / total_receipts_qty |
| slow_moving_flag | TRUE if days_inventory_outstanding > 90 OR turnover_ratio < 2 |

**Requirements**:
- Sort by warehouse_id, category_name
- Handle division by zero gracefully

## Data Sources

Use existing source definitions:

- `{{ source('inventory', 'INVENTORY_TRANSACTIONS') }}`
- `{{ source('product', 'PRODUCT_VARIANTS') }}`
- `{{ source('product', 'PRODUCTS') }}`
- `{{ source('product', 'PRODUCT_CATEGORIES') }}`

## Technical Constraints

1. **Pure SQL only** - No dbt Python models
2. **Strict FIFO ordering** - Receipts consumed in exact chronological order with transaction_id tiebreaker
3. **Warehouse isolation** - Each warehouse has independent FIFO queues
4. **Zero tolerance for FIFO violations** - Earlier receipts must be fully consumed before later ones
5. **Window functions required** - For cumulative calculations and range-based allocation
6. **Consistent date reference** - Use '2025-12-31' for aging calculations

## Validation Rules

Your solution must satisfy:
1. Sum of allocated_qty across all picks = Sum of fulfilled_units in monthly COGS
2. For any warehouse-variant, remaining_inventory = total_receipts - total_allocated
3. No pick should allocate from a receipt that occurred after the pick
4. FIFO order must be strict: if receipt A has earlier timestamp than B, A must be consumed first
5. All cumulative_qty_before values for first receipts must be exactly 0
