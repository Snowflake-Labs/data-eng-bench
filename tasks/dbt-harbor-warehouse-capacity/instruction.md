# Warehouse Capacity Planning & Peak Load Analysis

## Context

You are a data engineer at a retail company operating multiple distribution warehouses. Operations leadership needs visibility into warehouse capacity utilization, peak load periods, and staffing requirements to optimize fulfillment operations.

The database contains operational data across several schemas. Your focus will be on warehouse operations data - explore the database to understand the available tables related to orders, shipments, inventory movements, warehouses, and warehouse locations.

**Relevant schemas to explore**: `ORDERS`, `INVENTORY`

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

## Problem Statement

Build a dbt analytics pipeline that:
1. Analyzes hourly and daily order/shipment volume patterns per warehouse
2. Identifies peak load periods using statistical thresholds
3. Calculates warehouse utilization and throughput metrics
4. Flags warehouses approaching capacity constraints
5. Provides staffing recommendations based on workload patterns

## dbt Profile Setup

You must configure dbt to connect to the database:
- Create a `profiles.yml` in the dbt project directory with profile name `retail_dw_master`
- Set `DBT_PROFILES_DIR` environment variable to the directory containing `profiles.yml`

### DuckDB Profile
Configure with `type: duckdb` and the database path from `$DUCKDB_PATH`.

### Snowflake Profile
Configure with `type: snowflake` using password authentication:
- Use the environment variables for account, user, password, database, schema, warehouse, and role

## dbt Project Setup

- Create a new dbt project at `/app/dbt_project/`
- Profile name: `retail_dw_master`
- Your models must materialize into these schemas (with `main_` prefix):
  - `main_staging` - staging models
  - `main_intermediate` - intermediate transformation models
  - `main_marts` - final analytical models
- Important: Tests look specifically for `main_staging`, `main_intermediate`, and `main_marts`. If your models appear in `staging`/`intermediate`/`marts` or any other schema, adjust your dbt schema/target settings so the final schema names match `main_*`.
- Note: If your models appear in a different schema than expected, re-check your work and review how dbt handles schema naming when a custom schema is specified.
- Note: Required numeric columns must be cast to the specified types (e.g., DOUBLE/INTEGER). Implicit DECIMAL/HUGEINT types may fail tests.

## Required Models

### Staging Layer (schema: `main_staging`)

Create models in `models/staging/capacity/`:

**1. `stg_capacity__orders`**
- Purpose: Stage order data with time dimensions for capacity analysis
- Required columns: `order_id`, `warehouse_id`, `ordered_at`, `order_date` (DATE), `order_hour` (INTEGER 0-23), `day_of_week` (INTEGER 0=Sunday), `grand_total` (DOUBLE)
- Scope: Only include orders that have a warehouse assignment and valid timestamp

**2. `stg_capacity__shipments`**
- Purpose: Stage shipment data with timing information
- Required columns: `shipment_id`, `order_id`, `warehouse_id`, `shipped_at`, `shipment_date` (DATE), `shipment_hour` (INTEGER 0-23), `status`
- Scope: Only include shipments with valid shipped_at timestamp

### Intermediate Layer (schema: `main_intermediate`)

Create models in `models/intermediate/capacity/`:

**3. `int_capacity__hourly_volume`**
- Purpose: Aggregate order and shipment volumes by warehouse and hour
- Grain: One row per (warehouse_id, volume_date, volume_hour) combination
- Required columns:
  - `warehouse_id`, `volume_date`, `volume_hour`
  - `order_count` (INTEGER) - number of orders placed in that hour
  - `shipment_count` (INTEGER) - number of shipments dispatched in that hour
  - `order_value` (DOUBLE) - total order value for that hour
  - **Complete 24-hour grid requirement**: For every (warehouse_id, volume_date), include all 24 hours (0-23). Missing hours must be filled with 0s for `order_count`, `shipment_count`, and `order_value`.

**4. `int_capacity__daily_utilization`**
- Purpose: Calculate daily warehouse utilization metrics
- Grain: One row per (warehouse_id, utilization_date) combination
- Required columns:
  - `warehouse_id`, `utilization_date`
  - `daily_orders` (INTEGER) - total orders for the day
  - `daily_shipments` (INTEGER) - total shipments for the day
  - `daily_order_value` (DOUBLE) - total order value for the day
  - `location_count` (INTEGER) - number of warehouse locations (storage slots) for this warehouse
  - `theoretical_daily_capacity` (DOUBLE) - calculated as: `location_count * 0.05` (calibrated capacity factor per location per day)
  - `utilization_rate` (DOUBLE) - `daily_orders / theoretical_daily_capacity` (as decimal, e.g., 0.85 for 85%)

**5. `int_capacity__peak_periods`**
- Purpose: Identify peak hours using percentile-based detection
- Grain: One row per (warehouse_id, volume_date, volume_hour) combination
- Required columns:
  - `warehouse_id`, `volume_date`, `volume_hour`
  - `order_count`, `shipment_count`
  - `volume_percentile` (INTEGER) - percentile rank of this hour's order_count within its warehouse (use NTILE(100))
  - `is_peak_hour` (INTEGER) - 1 if volume_percentile >= 90, else 0

### Marts Layer (schema: `main_marts`)

Create models in `models/marts/capacity/`:

**6. `fct_warehouse_capacity`**
- Purpose: Comprehensive daily capacity metrics per warehouse
- Grain: One row per (warehouse_id, capacity_date) combination
- Required columns:
  - `warehouse_id`, `capacity_date`
  - `total_orders` (INTEGER) - daily order count
  - `total_shipments` (INTEGER) - daily shipment count
  - `total_order_value` (DOUBLE) - daily order value
  - `utilization_rate` (DOUBLE) - from daily utilization calculation
  - `peak_hour_count` (INTEGER) - number of hours flagged as peak that day
  - `avg_hourly_orders` (DOUBLE) - average orders per hour that day
  - `max_hourly_orders` (INTEGER) - maximum orders in any single hour that day
  - `peak_load_factor` (DOUBLE) - `CASE WHEN avg_hourly_orders = 0 THEN 1.0 ELSE max_hourly_orders / avg_hourly_orders END` (peaks vs average)
  - `capacity_headroom_pct` (DOUBLE) - `(1 - utilization_rate) * 100` (remaining capacity percentage)
  - `rolling_7d_avg_orders` (DOUBLE) - 7-day trailing average of `total_orders` per warehouse, using `ROWS BETWEEN 6 PRECEDING AND CURRENT ROW` ordered by `capacity_date`

**7. `rpt_capacity_bottlenecks`**
- Purpose: Flag warehouse-days that are approaching or exceeding capacity
- Source: Filter `fct_warehouse_capacity` where `utilization_rate >= 0.75`
- Required columns:
  - `warehouse_id`, `capacity_date`
  - `utilization_rate` (DOUBLE), `total_orders` (INTEGER), `peak_load_factor` (DOUBLE)
  - `bottleneck_severity` - categorize as:
    - `'CRITICAL'` if utilization_rate >= 0.95
    - `'HIGH'` if utilization_rate >= 0.85
    - `'MODERATE'` if utilization_rate >= 0.75
- Order by: `utilization_rate DESC, capacity_date DESC`
- Expectation: In the provided dataset, this report should contain at least one row. If it is empty, re-check your utilization calculation and joins.

## Business Logic Reference

**Utilization Calculation:**
```
Theoretical Daily Capacity = Warehouse Locations x 0.05 (calibrated capacity factor)
Utilization Rate = Daily Orders / Theoretical Daily Capacity
```

**Peak Detection:**
- Use `NTILE(100)` to assign percentile buckets to hourly volumes within each warehouse
- Hours in the 90th percentile or above are considered "peak hours"

**Peak Load Factor:**
```
Peak Load Factor = CASE WHEN Average Hourly Volume = 0 THEN 1.0 ELSE Max Hourly Volume / Average Hourly Volume END
```
A factor > 2.0 indicates highly variable demand patterns requiring flexible staffing.

**Rolling 7-Day Average Orders:**
```
rolling_7d_avg_orders = AVG(total_orders) OVER (
  PARTITION BY warehouse_id
  ORDER BY capacity_date
  ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
)
```

## Validation Criteria

Your solution will be tested for:
1. All 7 models exist in the correct schemas
2. All required columns are present with appropriate data types
3. Grain uniqueness - no duplicate key combinations in any model
4. Utilization rates are between 0 and 2 (some days may exceed capacity)
5. Peak detection correctly identifies top 10% busiest hours
6. At least one warehouse-day appears in the bottleneck report
7. Peak load factors are >= 1.0 (maximum is always >= average)
8. If avg_hourly_orders = 0, peak_load_factor must be 1.0 (not NULL)
9. For every (warehouse_id, volume_date), `int_capacity__hourly_volume` has exactly 24 hours (0-23) with no missing hours
10. No NULL values in critical metrics (utilization_rate, peak_load_factor)
11. The fact table must contain capacity metrics for multiple warehouses (at least 2)

## Guidelines

- Start by exploring the database to understand available tables and their relationships
- Warehouse location data may not have explicit capacity values - infer capacity from location counts
- Handle edge cases: days with no orders should not cause division by zero
- Some warehouses may have significantly different volumes - ensure your percentile calculations are warehouse-specific
- Use `dbt run --select model_name` to test individual models during development
