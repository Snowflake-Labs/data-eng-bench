# Fix Carrier Delivery Performance Model

## Problem

The logistics team uses the `rpt_carrier_performance` model to evaluate carrier delivery speed and reliability. However, the current model contains bugs that cause invalid metrics in reports and prevent proper carrier comparisons.

## Files

- DuckDB: `/app/dbt_models_duckdb/models/marts/sales/rpt_carrier_performance.sql`
- Snowflake: `/app/dbt_models_snowflake/models/marts/sales/rpt_carrier_performance.sql`

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

**stg_orders__shipments**: shipment_id, shipment_number, order_id, warehouse_id, carrier_id, shipping_method_id, status, SHIPPED_AT, DELIVERED_AT, SHIPPING_COST, WEIGHT

**Shipment Status Values**: `'CANCELLED'`, `'DELIVERED'`, `'IN_TRANSIT'`, `'PENDING'`, `'SHIPPED'`

## Current Issues

The existing model has critical problems:

1. Some calculated metrics show invalid values (infinity, NaN) in production dashboards
2. Row counts don't match expectations - some carriers are missing from output
3. A new classification column is needed to identify carriers requiring performance improvement
4. Missing peer comparison metrics for benchmarking

## Tasks

### 1. Fix Data Quality Issues

The model should include ALL carriers from the source table without invalid numeric values.

### 2. Add Percentile Rankings

Calculate these percentile metrics using `PERCENT_RANK()`:

| Column           | Description                                                   |
| ---------------- | ------------------------------------------------------------- |
| speed_percentile | Percentile by avg_delivery_days (faster = higher percentile)  |
| cost_percentile  | Percentile by avg_shipping_cost (cheaper = higher percentile) |

### 3. Add Delivery Speed Classification

Add a new column called `delivery_speed_tier` that classifies carriers by delivery performance.

Use the `speed_percentile` calculated above for tier classification.

**Tiers** (waterfall - check in order, first match wins):

| Tier              | Criteria                                                 |
| ----------------- | -------------------------------------------------------- |
| critical          | percentile <= 0.30 AND avg_delivery_days > 8             |
| needs_improvement | percentile <= 0.60 OR on_time_delivery_rate < 0.75       |
| excellent         | percentile >= 0.80 AND on_time_delivery_rate >= 0.92     |
| good              | on_time_delivery_rate >= 0.85 AND avg_delivery_days <= 5 |
| (default)         | All others ->`good`                                    |

**NULL Handling**: Treat NULL rates as 0. For NULL delivery days, treat as 0 when checking "greater than" conditions, and as 999 when checking "less than or equal" conditions.

### 4. Add Cost Tier Classification

Add `cost_tier` classifying carriers by cost efficiency:

| Tier       | Criteria                                                     |
| ---------- | ------------------------------------------------------------ |
| premium    | cost_percentile >= 0.80 AND delivery_completion_rate >= 0.90 |
| economical | cost_percentile >= 0.60 AND avg_shipping_cost < median       |
| standard   | cost_percentile >= 0.30                                      |
| expensive  | Default fallback                                             |

### 5. Add Peer Comparison Metrics

Add metrics that compare each carrier against peers within the same shipping method:

| Column                | Description                                                                  |
| --------------------- | ---------------------------------------------------------------------------- |
| peer_rank             | Rank within shipping_method_id by avg_delivery_days (fastest = 1)            |
| peer_count            | Total carriers using the same shipping_method_id                             |
| above_peer_avg        | 1 if carrier's on_time_delivery_rate > avg for their shipping method, else 0 |
| peer_speed_percentile | PERCENT_RANK within shipping_method_id by avg_delivery_days (faster=higher)  |

### 6. Add Carrier Efficiency Index

Calculate a composite `carrier_efficiency_index` (0-100) as a weighted sum:

| Factor             | Calculation                        | Weight |
| ------------------ | ---------------------------------- | ------ |
| fulfillment_factor | delivery_completion_rate           | 30%    |
| speed_factor       | Delivery speed vs 14-day benchmark | 25%    |
| on_time_factor     | on_time_delivery_rate              | 25%    |
| cost_factor        | Cost efficiency vs median          | 20%    |

- **Fulfillment factor**: Use delivery_completion_rate directly (already 0-1)
- **Speed factor**: How close delivery time is to a 14-day target. A carrier delivering in 0 days scores 1.0; a carrier at or above 14 days scores 0.0. Scale linearly between these: subtract the fraction of days used out of 14, capping the result between 0 and 1. If avg_delivery_days is NULL, default to 14 (worst case, score = 0).
- **On-time factor**: Use on_time_delivery_rate directly (already 0-1)
- **Cost factor**: How much cheaper a carrier is compared to the median cost across all carriers. A carrier at half the median scores 1.0; a carrier at double the median scores 0.0. Specifically, compute how far above or below the median the carrier's cost is as a ratio, then invert and cap between 0 and 1. If avg_shipping_cost is NULL, default to the median (neutral score).

All factors capped 0-1. Final index = weighted sum x 100, bounded 0-100.

### 7. Add Carrier Reliability Index

Calculate a `carrier_reliability_index` (0-100) combining:

| Factor            | Weight |
| ----------------- | ------ |
| completion_factor | 40%    |
| speed_consistency | 30%    |
| volume_factor     | 30%    |

- **Completion factor**: Use delivery_completion_rate directly (already 0-1). If NULL, default to 0.
- **Speed consistency**: Measure the delivery time spread (max_delivery_days - min_delivery_days) relative to avg_delivery_days, then halve it. A carrier with zero spread scores 1.0; a carrier whose spread-to-average ratio reaches 2.0 or more scores 0.0. Scale linearly between these, capping at 0-1. If avg_delivery_days is 0 or NULL, default to 1.0 (no variance data = assume consistent).
- **Volume factor**: Ratio of a carrier's total_shipments to the median total_shipments across all carriers, capped at 1.0. Carriers at or above median volume score 1.0; smaller carriers score proportionally less.

All factors normalized 0-1, final index = weighted sum x 100, bounded 0-100.

## Expected Output

The model should produce these columns:

- `carrier_id`
- `shipping_method_id` (primary shipping method = the one with the most shipments for this carrier)
- `total_shipments`
- `delivered_shipments`
- `in_transit_shipments`
- `cancelled_shipments`
- `total_shipping_cost`
- `avg_shipping_cost`
- `total_weight`
- `avg_weight`
- `avg_delivery_days`
- `min_delivery_days`
- `max_delivery_days`
- `on_time_shipments` (delivered within 7 days)
- `on_time_delivery_rate` (proportion of delivered shipments delivered on time)
- `delivery_completion_rate` (proportion of all shipments that were delivered)
- `speed_percentile`
- `cost_percentile`
- `delivery_speed_tier`
- `cost_tier`
- `peer_rank`
- `peer_count`
- `above_peer_avg`
- `peer_speed_percentile`
- `carrier_efficiency_index`
- `carrier_reliability_index`

## Guidelines
- Do NOT modify upstream staging models
- Do NOT change model materialization
- Preserve all output columns
