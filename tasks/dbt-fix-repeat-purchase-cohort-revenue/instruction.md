### Task: Fix Repeat Purchase Cohort Revenue

You are repairing a **repeat purchase cohort revenue** mart using dbt.

## Database Backend

This task supports both **DuckDB** and **Snowflake** backends. The `DB_TYPE` environment variable determines which backend to use (`duckdb` or `snowflake`).

- **DuckDB mode**: The model materializes in the `analytics` schema (table: `analytics.rpt_repeat_purchase_cohort_revenue_fixed`)
- **Snowflake mode**: The model materializes in the `main` schema (table: `main.rpt_repeat_purchase_cohort_revenue_fixed`)

## Project Setup

### DuckDB Mode
The reference project is at `/app/dbt_models_duckdb` and the database is at `/app/database/retail.duckdb`. Your project lives at `/app/dbt_project`.

Before building the mart model, you must first build the staging models in `/app/dbt_models_duckdb`:
```bash
cd /app/dbt_models_duckdb && dbt deps && dbt run --select int_sales__orders_enriched
```

Create the dbt model at:
`/app/dbt_project/models/marts/customer/rpt_repeat_purchase_cohort_revenue_fixed.sql`

The dbt project should be configured to use the `analytics` schema for materialized models.

### Snowflake Mode
Use the pre-existing dbt project at `/app/dbt_models_snowflake`. Create a symlink so the project is also available at `/app/dbt_project`:
```bash
ln -sfn /app/dbt_models_snowflake /app/dbt_project
```

The staging models (`int_sales__orders_enriched`) are already pre-built in the Snowflake clone. You only need to write and run the mart model.

Write the model to: `/app/dbt_models_snowflake/models/marts/customer/rpt_repeat_purchase_cohort_revenue_fixed.sql`

## dbt Profile Setup

### DuckDB
```yaml
dbt_project:
  target: dev
  outputs:
    dev:
      type: duckdb
      path: /app/database/retail.duckdb
      schema: analytics
```

### Snowflake
Generate a `profiles.yml` in the project directory using Snowflake environment variables (`SNOWFLAKE_ACCOUNT`, `SNOWFLAKE_USER`, `SNOWFLAKE_PASSWORD`, `SNOWFLAKE_DATABASE`, `SNOWFLAKE_WAREHOUSE`, `SNOWFLAKE_ROLE`). Use the `retail_dw_master` profile with `schema: main` and password authentication.

Implement **one** model: `models/marts/customer/rpt_repeat_purchase_cohort_revenue_fixed.sql`.

#### Output table
- `cohort_month` (DATE) -- first purchase month (first day of month)
- `months_since_cohort` (INTEGER) -- 0 for cohort month; never negative
- `cohort_size` (INTEGER) -- distinct customers per cohort (constant within a cohort)
- `active_customers` (INTEGER) -- distinct customers ordering in the months-since bucket
- `orders` (INTEGER) -- distinct orders in the bucket
- `revenue` (DECIMAL(18,2)) -- bucket revenue
- `cumulative_revenue` (DECIMAL(18,2)) -- running revenue per cohort ordered by `months_since_cohort`

#### Business rules (strict)
- Source relation: `main.int_sales__orders_enriched` (build it from `/app/dbt_models_duckdb` for DuckDB; pre-built in Snowflake clone). **Note**: This table may contain multiple rows per `order_id`. Deduplicate to one row per order before computing cohorts. When deduplicating, use `MIN()` aggregation: `MIN(customer_id)` to resolve conflicting customer IDs, `MIN(ordered_at)` for timestamps, and `SUM()` for monetary values (to preserve total revenue). This ensures total revenue reconciles with the source.
- Cohort definition: `cohort_month = date_trunc('month', min(ordered_at))::date` per `customer_id`.
- **NULL customer_id handling**: Some orders have NULL `customer_id`. These orders must still be included in total `orders` counts and `revenue` totals (for reconciliation against source), but should NOT be counted toward `cohort_size` (which only counts real customers with non-NULL customer_id). Consider assigning synthetic customer keys to NULL customer_id rows so they remain in the dataset.
- Per-order fields:
  - `order_month = date_trunc('month', ordered_at)::date`
  - `months_since_cohort = date_diff('month', cohort_month, order_month)` (DuckDB) or `DATEDIFF('month', cohort_month, order_month)` (Snowflake)
  - Ignore orders with NULL `ordered_at`; keep `grand_total` as-is (no negatives expected).
- Aggregation grain `(cohort_month, months_since_cohort)`:
  - `active_customers = count(distinct customer_id)`
  - `orders = count(distinct order_id)`
  - `revenue = cast(sum(grand_total) as decimal(18,2))`
- `cohort_size = count(distinct customer_id)` per `cohort_month` (attach to every bucket).
- `cumulative_revenue = sum(revenue) over (partition by cohort_month order by months_since_cohort rows unbounded preceding)`.

#### Quality + invariants (enforced)
- No NULLs in `cohort_month` or `months_since_cohort`; `months_since_cohort >= 0`.
- `active_customers <= cohort_size` for every row.
- `revenue >= 0` and `cumulative_revenue >= revenue`.
- `cumulative_revenue` non-decreasing within a cohort.
- For each cohort, `cohort_size` must equal the number of distinct customers in that cohort's first-order month (recomputed from source).
- Global reconciliation vs source: total `orders` must match to +/-1; total `revenue` must match within 0.5% relative error.
- Cumulative check: for every cohort/month bucket, `cumulative_revenue` must equal the sum of all prior-or-equal bucket revenues (tolerance 0.01).
- Idempotent and deterministic: reruns should not change totals.

#### SQL Compatibility Guidelines
- Use Jinja conditionals (`{% if target.type == 'snowflake' %}`) for database-specific syntax where needed
- DuckDB uses `DATE_DIFF('month', start, end)` while Snowflake uses `DATEDIFF('month', start, end)`
- DuckDB `::date` cast works, but prefer `CAST(... AS DATE)` for cross-compatibility
- Use `adapter.get_relation()` to reference source tables from the `main` schema
- Avoid DuckDB-specific `FILTER (WHERE ...)` syntax; use `CASE WHEN` for Snowflake compatibility

#### Environment notes
- Check `DB_TYPE` environment variable to determine which backend is active.
- DuckDB project dir: `/app/dbt_models_duckdb`; Snowflake project dir: `/app/dbt_models_snowflake`
- Do not modify `/app/dbt_models_duckdb` or `/app/dbt_models_snowflake` staging models; depend on them by building first (DuckDB) or relying on pre-built (Snowflake).
- Avoid fanout: aggregate only once; window over aggregated data.
- **Schema Configuration**:
  - For DuckDB: Ensure your model materializes in the `analytics` schema exactly (not `main_analytics` or similar). Review dbt's schema naming conventions if needed.
  - For Snowflake: The model should materialize in the `main` schema (the default schema for the Snowflake profile).
