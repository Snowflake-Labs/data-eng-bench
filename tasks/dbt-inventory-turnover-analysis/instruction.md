### Task: Inventory Turnover and Days of Supply Analysis

You're an analytics engineer building an **inventory performance metrics** mart for supply chain optimization.

## Database Backend

This task supports two database backends:

- **DuckDB**: Local DuckDB database at `/app/database/retail.duckdb`. The reference dbt project is at `/app/dbt_models_duckdb/`. Create your agent dbt project at `/app/dbt_project`.
- **Snowflake**: Cloud Snowflake database. Connection details are provided via environment variables (`SNOWFLAKE_ACCOUNT`, `SNOWFLAKE_USER`, `SNOWFLAKE_PASSWORD`, `SNOWFLAKE_DATABASE`, `SNOWFLAKE_SCHEMA`, `SNOWFLAKE_WAREHOUSE`, `SNOWFLAKE_ROLE`). The reference dbt project is at `/app/dbt_models_snowflake/`. Create your agent dbt project at `/app/dbt_project`.

Check the `DB_TYPE` environment variable to determine which backend is active.

**Note**: For Snowflake, the entrypoint automatically creates a clone database and sets `SNOWFLAKE_DATABASE`. The clone is destroyed when the task completes.

## dbt Profile Setup

You must configure dbt to connect to the database:
- Create a `profiles.yml` in your dbt project directory with profile name `dbt_project`
- Set `DBT_PROFILES_DIR` environment variable to the directory containing `profiles.yml`

### DuckDB Profile
Configure with `type: duckdb` and the database path from `$DUCKDB_PATH` (default: `/app/database/retail.duckdb`). Set schema to `analytics`.

### Snowflake Profile
Configure with `type: snowflake` using password authentication:
- Use the environment variables for account, user, database, schema (`analytics`), warehouse, and role

## Task

The warehouse already contains a reference dbt project with staging models. For DuckDB, it is at `/app/dbt_models_duckdb`; for Snowflake, it is at `/app/dbt_models_snowflake`.

Create a dbt project at `/app/dbt_project` and implement:
- `models/marts/inventory/rpt_inventory_turnover_analysis.sql`

#### Output table
Materialize `analytics.rpt_inventory_turnover_analysis` with columns:
- `sku` (STRING)
- `warehouse_id` (STRING)
- `product_category` (STRING)
- `analysis_period_days` (INTEGER)
- `total_units_sold` (INTEGER)
- `avg_inventory_on_hand` (NUMERIC(18,2))
- `inventory_turnover_ratio` (NUMERIC(18,4))
- `days_of_supply` (NUMERIC(18,2))
- `turnover_velocity_class` (STRING)
- `current_quantity_on_hand` (INTEGER)
- `estimated_days_until_stockout` (NUMERIC(18,2))

#### Business rules
- Source data (build via the reference dbt project):
  - `main.stg_orders__order_lines`
  - `main.stg_orders__orders`
  - `main.stg_inventory__inventory_levels`
  - `main.stg_product__product_variants`
  - `main.stg_product__products`
- Analysis period:
  - Use orders from the **last 180 days** relative to the most recent fulfillment date in the data (do NOT use CURRENT_DATE).
  - Only include orders with non-null `shipped_at` or `delivered_at`.
  - Only include orders with `fulfillment_status = 'FULFILLED'`.
  - Use `COALESCE(shipped_at, delivered_at)` as the fulfillment date.
  - Calculate `analysis_period_days` as the actual number of days between the earliest and latest fulfilled order in the period (max 180).
- Sales calculation:
  - Join `stg_orders__order_lines` to `stg_orders__orders` on `order_id`.
  - Sum `quantity_ordered` as `total_units_sold` per `(sku, warehouse_id)`.
  - Filter to fulfilled orders within the 180-day window.
- Inventory calculation:
  - Use `stg_inventory__inventory_levels` joined to `stg_product__product_variants` to get `sku`.
  - Join `stg_product__product_variants` to `stg_product__products` on `product_id` to derive `product_category`. The `stg_product__products` table does not have a `product_category` column. Instead, derive it using: `COALESCE(p.product_type, p.primary_category_id, 'UNKNOWN') AS product_category`. The table has columns `product_type`, `primary_category_id`, `legacy_category_code`, and `old_category_id` - use `product_type` first, then fall back to `primary_category_id`, then `'UNKNOWN'` if both are NULL.
  - For each `(sku, warehouse_id)`, calculate `avg_inventory_on_hand` as the average of `quantity_on_hand` across all inventory snapshots in the analysis period.
  - If no inventory snapshots exist in the period, use the most recent snapshot before the period end.
  - `current_quantity_on_hand` is the latest `quantity_on_hand` value.
- Metrics (per `sku`, `warehouse_id`):
  - `inventory_turnover_ratio = total_units_sold / NULLIF(avg_inventory_on_hand, 0)`
  - `days_of_supply = (avg_inventory_on_hand * analysis_period_days) / NULLIF(total_units_sold, 0)`
  - `estimated_days_until_stockout = current_quantity_on_hand / NULLIF((total_units_sold / analysis_period_days), 0)`
- Velocity classification:
  - `turnover_velocity_class` based on `inventory_turnover_ratio`:
    - `'FAST'` if `>= 12.0` (turns over monthly or faster)
    - `'MEDIUM'` if `>= 4.0` (turns over quarterly or faster)
    - `'SLOW'` if `>= 1.0` (turns over annually or faster)
    - `'STAGNANT'` if `< 1.0` or NULL
- Edge cases:
  - If `total_units_sold = 0`, set `inventory_turnover_ratio = 0`, `days_of_supply = NULL`, `estimated_days_until_stockout = NULL`.
  - If `avg_inventory_on_hand = 0` and `total_units_sold > 0`, set `inventory_turnover_ratio = NULL`, `days_of_supply = 0`.
  - If `current_quantity_on_hand = 0`, set `estimated_days_until_stockout = 0`.

#### Quality requirements
- No NULL `sku` or `warehouse_id` for rows with non-zero `current_quantity_on_hand`.
- All numeric measures must be **non-negative** (except NULLs where specified).
- Logical bounds:
  - `inventory_turnover_ratio >= 0` (or NULL)
  - `days_of_supply >= 0` (or NULL)
  - `estimated_days_until_stockout >= 0` (or NULL)
  - `analysis_period_days` between 1 and 180 (inclusive).
- Reconciliation sanity:
  - For a sample of top SKUs by `current_quantity_on_hand`, verify `total_units_sold` matches direct aggregation from `stg_orders__order_lines` + `stg_orders__orders` within the same period.
  - Verify `inventory_turnover_ratio * days_of_supply ≈ analysis_period_days` (within 0.1 tolerance) when both are non-NULL.

#### Environment notes
- Base image includes dbt + DuckDB + Snowflake support + reference dbt project.
- Your dbt profile should write to schema `analytics`.
- Use Jinja conditionals (`{% if target.type == 'snowflake' %}`) for database-specific syntax.

#### Guidelines
- Do NOT modify upstream staging models.
- Preserve all output columns.
