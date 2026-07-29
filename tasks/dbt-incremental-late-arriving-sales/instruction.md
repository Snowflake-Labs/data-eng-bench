# Incremental Sales Pipeline with Late-Arriving Data Handling

## Background

Offline POS orders sync days after the actual sale, causing revenue reports to be understated until all late-arriving data settles. Finance needs to understand restatement impact and channel-specific latency patterns.

## Files

- DuckDB: `/app/dbt_models_duckdb/models/marts/incremental/`
- Snowflake: `/app/dbt_models_snowflake/models/marts/incremental/`

Create models in `models/marts/incremental/`.

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

## Source Data

Use `{{ source('orders', 'ORDERS') }}` with key timestamps:
- `ORDERED_AT`: When the sale actually occurred
- `CREATED_AT`: When the order entered the system

Exclude orders where `TEST_ORDER_FLAG = true`.

## Required Models (7 total)

### 1. `order_version_history.sql`

SCD Type 2 tracking of order changes. When the same `ORDER_ID` appears multiple times with different `CREATED_AT`, each represents a version.

| Column | Description |
|--------|-------------|
| order_id | Order identifier |
| version_num | Sequential version (1, 2, 3...) |
| valid_from | When this version became active (CREATED_AT) |
| valid_to | When superseded (next version's CREATED_AT), NULL if current |
| is_current | TRUE for latest version |
| grand_total | Order total for this version |
| status | Order status |
| customer_id | Customer identifier |
| channel_id | Sales channel |
| ordered_at | Business timestamp |
| created_at | System timestamp |

### 2. `incremental_daily_sales.sql`

Incremental model with adaptive lookback window. Must use `materialized='incremental'` with `unique_key='order_id'`.

For incremental runs, look back based on p95 historical arrival latency plus a buffer (not just `max(created_at)`). Use 7 days as fallback when no historical latency data exists.

| Column | Description |
|--------|-------------|
| order_id | Order identifier |
| order_date | DATE from ORDERED_AT |
| customer_id | Customer identifier |
| channel_id | Sales channel |
| grand_total | Final order total (from current version) |
| status | Current status |
| ordered_at | Business timestamp |
| created_at | Latest system timestamp |
| loaded_at | When loaded into this model |
| arrival_latency_days | Days between ordered_at and created_at |
| version_count | Number of versions seen for this order |

### 3. `channel_latency_analysis.sql`

Per-channel latency profiles. Different channels have different late-arrival patterns.

**Note**: Only include orders with valid latency (where `created_at >= ordered_at`).

| Column | Description |
|--------|-------------|
| channel_id | Sales channel identifier |
| total_orders | Order count (valid latency only) |
| avg_latency_hours | Average arrival latency |
| p50_latency_hours | Median latency |
| p95_latency_hours | 95th percentile latency |
| on_time_pct | % arriving within 1 day |
| late_1_3_pct | % arriving 1-3 days late |
| late_3_7_pct | % arriving 3-7 days late |
| late_7_plus_pct | % arriving 7+ days late |

### 4. `revenue_reconciliation_waterfall.sql`

Track how reported daily revenue changes as late orders arrive. For each order_date, show revenue captured at different time horizons.

| Column | Description |
|--------|-------------|
| order_date | Business date |
| initial_revenue | Revenue from orders with latency <= 1 day |
| adj_day_1_2 | Revenue from orders with latency > 1 and <= 2 days |
| adj_day_3_7 | Revenue from orders with latency > 2 and <= 7 days |
| adj_day_8_plus | Revenue from orders with latency > 7 days |
| settled_revenue | Total final revenue (sum of all buckets) |
| restatement_pct | (settled - initial) / initial * 100, NULL if initial = 0 |
| order_count | Total orders for this date |

### 5. `late_arrival_metrics.sql`

Daily late-arrival statistics with probabilistic completeness estimation.

| Column | Description |
|--------|-------------|
| order_date | Business date |
| total_orders | Orders received for this date |
| orders_on_time | Orders with latency <= 1 day |
| orders_late_1_3 | Orders with latency > 1 and <= 3 days |
| orders_late_3_7 | Orders with latency > 3 and <= 7 days |
| orders_late_7_plus | Orders with latency > 7 days |
| avg_latency_hours | Mean arrival latency |
| p95_latency_hours | 95th percentile latency |
| days_since_order | Days from order_date to the most recent order date in the data |
| completeness_pct | Estimated % of orders received |
| completeness_lower | 95% confidence lower bound |
| completeness_upper | 95% confidence upper bound |

Completeness estimation: Use historical arrival curves. For dates within the typical latency window, estimate based on day-of-week patterns and time elapsed.

### 6. `order_data_quality.sql`

Quality scoring per order.

| Column | Description |
|--------|-------------|
| order_id | Order identifier |
| order_date | Business date |
| has_future_order_date | ordered_at > created_at |
| has_negative_total | grand_total < 0 |
| has_null_customer | customer_id is NULL |
| has_extreme_latency | latency > 30 days |
| issue_count | Number of issues (0-4) |
| quality_score | 100 - (25 * issue_count) |

### 7. `daily_sales_summary.sql`

Aggregated daily summary using quality-filtered data.

| Column | Description |
|--------|-------------|
| order_date | Business date |
| total_orders | Order count (quality_score >= 75 only) |
| total_revenue | Sum of grand_total |
| unique_customers | Distinct customer count |
| avg_order_value | Mean order value |
| completeness_pct | From late_arrival_metrics |
| provisional_flag | TRUE if completeness_pct < 90 |
| restatement_risk | From revenue_reconciliation_waterfall |

## Technical Requirements

1. Incremental model must handle re-running correctly (idempotent)
2. Late-arriving orders must be captured on subsequent runs
3. Order corrections (same order_id, new created_at) must update existing records
4. All percentages rounded to 2 decimal places
5. All monetary values rounded to 2 decimal places

## Guidelines

- The SQL syntax should work on both DuckDB and Snowflake (ANSI SQL compatible)
- Use MAX(order_date) from the sales data as the reference date for time-elapsed calculations like days_since_order (do NOT use CURRENT_DATE — the data may not extend to the present day)
