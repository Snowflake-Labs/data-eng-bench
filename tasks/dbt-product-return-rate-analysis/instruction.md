### Task: Product Return Rate Analysis (dbt)

You are building a **product return rate** reporting system using dbt. Your project lives at `/app/dbt_project`.

## Files
- DuckDB: `/app/dbt_models_duckdb/` (reference project)
- Snowflake: `/app/dbt_models_snowflake/` (reference project)
- Your project: `/app/dbt_project/`

Implement **three models** in a layered architecture: staging, intermediate, and mart.

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
- Create a `profiles.yml` in the dbt project directory with profile name `dbt_project`
- Set `DBT_PROFILES_DIR` environment variable to the directory containing `profiles.yml`

### DuckDB Profile
Configure with `type: duckdb` and the database path from `$DUCKDB_PATH`.

### Snowflake Profile
Configure with `type: snowflake` using password authentication:
- Use the environment variables for account, user, password, database, schema, warehouse, and role

## Sources

- `main.int_sales__orders_enriched` (from reference project): `order_id`, `ordered_at`, `customer_id`, `status`
- `main.int_sales__order_lines` (from reference project): `order_line_id`, `order_id`, `product_id`, `sku`, `quantity_ordered`, `line_total`
- `{{ source('orders', 'RETURN_LINES') }}` (schema `ORDERS`): `order_line_id`, `quantity_returned`, `reason_id`, `created_at` (return date)
- `{{ source('orders', 'RETURN_REASONS') }}` (schema `ORDERS`): `reason_id`, `reason_name` (use as return reason; treat NULL as `'UNKNOWN'` for top-reason logic)

Define the `orders` source with tables `RETURN_LINES` and `RETURN_REASONS` in schema `ORDERS` (e.g. in `models/sources.yml`).

## Required Models

### 1. Staging: `stg_product_returns.sql`

Location: `models/staging/stg_product_returns.sql`

**Purpose**: Clean and normalize return data with order context

**Requirements**:
- Join `main.int_sales__order_lines` with `main.int_sales__orders_enriched` on `order_id`
- Join to `{{ source('orders', 'RETURN_LINES') }}` on `order_line_id`
- Join to `{{ source('orders', 'RETURN_REASONS') }}` on `reason_id`
- Filter: `product_id IS NOT NULL`, `status NOT IN ('CANCELLED', 'FAILED')`, `quantity_returned > 0`
- Calculate `days_to_return`: `EXTRACT(EPOCH FROM (return_date - ordered_at)) / 86400.0` where `return_date >= ordered_at`
- Use `COALESCE(sku, product_id)` for `sku`
- Use `COALESCE(reason_name, 'UNKNOWN')` for `return_reason`
- Calculate `return_revenue_impact`: `line_total * (quantity_returned / NULLIF(quantity_ordered, 0))`

**Output columns**:
- `order_line_id` (VARCHAR)
- `order_id` (VARCHAR)
- `product_id` (VARCHAR)
- `sku` (VARCHAR)
- `customer_id` (VARCHAR)
- `ordered_at` (TIMESTAMP)
- `return_date` (TIMESTAMP)
- `quantity_ordered` (INTEGER)
- `quantity_returned` (INTEGER)
- `line_total` (DECIMAL(18,2))
- `return_reason` (VARCHAR)
- `days_to_return` (DOUBLE)
- `return_revenue_impact` (DECIMAL(18,2))

### 2. Intermediate: `int_product_return_metrics.sql`

Location: `models/intermediate/int_product_return_metrics.sql`

**Purpose**: Calculate product-level return metrics with percentiles and cohort analysis

**Requirements**:
- Reference `stg_product_returns` via `{{ ref('stg_product_returns') }}`
- Group by `product_id`, `sku`, `month_start` (where `month_start = date_trunc('month', ordered_at)::DATE`)
- Calculate base metrics:
  - `units_ordered`: `SUM(quantity_ordered)` from order lines (join back to `main.int_sales__order_lines` and `main.int_sales__orders_enriched` with same filters)
  - `units_returned`: `SUM(quantity_returned)`
  - `return_rate`: `units_returned / NULLIF(units_ordered, 0)`
  - `return_revenue_impact`: `SUM(return_revenue_impact)`
  - `customers_affected`: `COUNT(DISTINCT customer_id)`
  - `avg_days_to_return`: `AVG(days_to_return)`
- Calculate percentile metrics (using `PERCENTILE_CONT`):
  - `p25_days_to_return`: 25th percentile of `days_to_return`
  - `p50_days_to_return`: 50th percentile (median) of `days_to_return`
  - `p75_days_to_return`: 75th percentile of `days_to_return`
  - `p25_return_rate`: 25th percentile of return rates across order lines (calculate per order line first: `quantity_returned / NULLIF(quantity_ordered, 0)`, then percentile)
  - `p50_return_rate`: 50th percentile
  - `p75_return_rate`: 75th percentile
- Calculate return velocity segments:
  - `fast_returns` (INTEGER): count where `days_to_return <= 7`
  - `medium_returns` (INTEGER): count where `7 < days_to_return <= 30`
  - `slow_returns` (INTEGER): count where `days_to_return > 30`
- Calculate top return reason:
  - `top_return_reason`: most common `return_reason` (by count of return lines)
  - `return_reason_count`: count of return lines for top reason
  - Use `ROW_NUMBER()` with `ORDER BY COUNT(*) DESC, return_reason` to break ties

**Output columns**:
- `month_start` (DATE)
- `product_id` (VARCHAR)
- `sku` (VARCHAR)
- `units_ordered` (INTEGER)
- `units_returned` (INTEGER)
- `return_rate` (DECIMAL(10,6))
- `return_revenue_impact` (DECIMAL(18,2))
- `customers_affected` (INTEGER)
- `avg_days_to_return` (DECIMAL(12,4))
- `p25_days_to_return` (DECIMAL(12,4))
- `p50_days_to_return` (DECIMAL(12,4))
- `p75_days_to_return` (DECIMAL(12,4))
- `p25_return_rate` (DECIMAL(10,6))
- `p50_return_rate` (DECIMAL(10,6))
- `p75_return_rate` (DECIMAL(10,6))
- `fast_returns` (INTEGER)
- `medium_returns` (INTEGER)
- `slow_returns` (INTEGER)
- `top_return_reason` (VARCHAR)
- `return_reason_count` (INTEGER)

### 3. Mart: `rpt_product_return_rates_monthly.sql`

Location: `models/marts/product/rpt_product_return_rates_monthly.sql`

**Purpose**: Final reporting table with trend analysis and cohort metrics

**Requirements**:
- Reference `int_product_return_metrics` via `{{ ref('int_product_return_metrics') }}`
- Include all columns from `int_product_return_metrics`
- Add trend metrics using window functions:
  - `prev_month_return_rate` (DECIMAL(10,6)): `LAG(return_rate) OVER (PARTITION BY product_id ORDER BY month_start)`
  - `mom_return_rate_change` (DECIMAL(10,6)): `return_rate - prev_month_return_rate`; NULL when no previous month
  - `mom_return_rate_change_pct` (DECIMAL(10,4)): `(mom_return_rate_change / NULLIF(prev_month_return_rate, 0)) * 100`; NULL when no previous month or prev_month_return_rate = 0
- Add cohort analysis:
  - `first_return_month` (DATE): `MIN(month_start) OVER (PARTITION BY product_id)` where `units_returned > 0`
  - `months_since_first_return` (INTEGER): `DATEDIFF('month', first_return_month, month_start)`; NULL when no returns yet
  - `is_first_return_month` (BOOLEAN): `month_start = first_return_month`
- Add return velocity rate:
  - `fast_return_rate` (DECIMAL(10,6)): `fast_returns / NULLIF(units_returned, 0)`
  - `medium_return_rate` (DECIMAL(10,6)): `medium_returns / NULLIF(units_returned, 0)`
  - `slow_return_rate` (DECIMAL(10,6)): `slow_returns / NULLIF(units_returned, 0)`
- Handle NULLs: when `units_returned = 0`, set `return_rate = 0`, `top_return_reason = NULL`, `return_reason_count = 0`, all days-to-return metrics = NULL, all return velocity metrics = 0, all trend metrics = NULL.

**Output columns** (in order):
- `month_start` (DATE)
- `product_id` (VARCHAR)
- `sku` (VARCHAR)
- `units_ordered` (INTEGER)
- `units_returned` (INTEGER)
- `return_rate` (DECIMAL(10,6))
- `return_revenue_impact` (DECIMAL(18,2))
- `customers_affected` (INTEGER)
- `avg_days_to_return` (DECIMAL(12,4))
- `p25_days_to_return` (DECIMAL(12,4))
- `p50_days_to_return` (DECIMAL(12,4))
- `p75_days_to_return` (DECIMAL(12,4))
- `p25_return_rate` (DECIMAL(10,6))
- `p50_return_rate` (DECIMAL(10,6))
- `p75_return_rate` (DECIMAL(10,6))
- `fast_returns` (INTEGER)
- `medium_returns` (INTEGER)
- `slow_returns` (INTEGER)
- `fast_return_rate` (DECIMAL(10,6))
- `medium_return_rate` (DECIMAL(10,6))
- `slow_return_rate` (DECIMAL(10,6))
- `top_return_reason` (VARCHAR)
- `return_reason_count` (INTEGER)
- `prev_month_return_rate` (DECIMAL(10,6))
- `mom_return_rate_change` (DECIMAL(10,6))
- `mom_return_rate_change_pct` (DECIMAL(10,4))
- `first_return_month` (DATE)
- `months_since_first_return` (INTEGER)
- `is_first_return_month` (BOOLEAN)

## Business rules (strict)

- Exclude rows where `product_id` is NULL.
- Only include orders with `status NOT IN ('CANCELLED', 'FAILED')`.
- Only count returns where `quantity_returned > 0`.
- When no returns exist for a product/month: `return_rate` = 0, `top_return_reason` = NULL, `return_reason_count` = 0, all days-to-return metrics = NULL, all return velocity counts = 0, all trend metrics = NULL.
- For `days_to_return` calculations, include only returns where `return_date >= ordered_at`.
- Percentile calculations use `PERCENTILE_CONT` (continuous).
- Window functions for trends must partition by `product_id` and order by `month_start`.

## Quality + invariants (enforced)

- `return_rate` between 0 and 1 (inclusive).
- `units_returned <= units_ordered` for every row.
- `return_revenue_impact` = 0 when `units_returned` = 0; non-negative when `units_returned` > 0.
- `customers_affected` >= 0.
- `sku` must not be NULL (use `product_id` when source `sku` is NULL).
- When `units_returned` > 0: `top_return_reason` and `return_reason_count` must be non-NULL and `return_reason_count` > 0.
- Percentile ordering: `p25 <= p50 <= p75` for both days and return rates.
- Return velocity rates sum to 1.0 when `units_returned > 0`: `fast_return_rate + medium_return_rate + slow_return_rate = 1.0` (within 0.0001 tolerance).
- Output reconciles with source: total `units_ordered` and `units_returned` within tolerances used by the grader.

## Guidelines

- Use ANSI SQL syntax compatible with both DuckDB and Snowflake.
- Do not modify the reference project; depend on it via `dbt run --select int_sales__orders_enriched int_sales__order_lines` before your models.
- Materialize staging as `view`, intermediate as `table`, mart as `table`.
- Profile writes to schema `analytics` (e.g. `schema: analytics` in `profiles.yml`).
