# Build Warehouse Fulfillment Analytics Model

## Overview

Create a dbt model analyzing warehouse fulfillment performance with operational metrics, peer comparison, and efficiency scoring.

## Files

- DuckDB: `/app/dbt_models_duckdb/models/marts/inventory/rpt_warehouse_fulfillment.sql`
- Snowflake: `/app/dbt_models_snowflake/models/marts/inventory/rpt_warehouse_fulfillment.sql`

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

- `int_sales__orders_enriched` - Orders (exclude CANCELLED status, note: mixed case status values)
- `stg_orders__shipments` - Shipment records with warehouse_id, shipped_at, delivered_at
- `stg_inventory__warehouses` - Warehouse master data

**Warehouse Scope**: Include all warehouses that have shipments in `stg_orders__shipments` (where warehouse_id IS NOT NULL) AND exist in `stg_inventory__warehouses`. One row per warehouse.

## Required Output Columns

| Column                 | Type    | Description                                |
| ---------------------- | ------- | ------------------------------------------ |
| warehouse_id           | varchar | Warehouse identifier                       |
| warehouse_name         | varchar | Warehouse name                             |
| warehouse_type         | varchar | Warehouse type                             |
| total_orders           | integer | Orders assigned to warehouse               |
| total_shipped          | integer | Orders that shipped                        |
| total_delivered        | integer | Orders delivered                           |
| avg_ship_time_days     | decimal | Average days from order to shipment        |
| avg_delivery_time_days | decimal | Average days from shipment to delivery     |
| fulfillment_rate       | decimal | Shipped / Orders (0-1)                     |
| delivery_success_rate  | decimal | Delivered / Shipped (0-1)                  |
| on_time_delivery_rate  | decimal | Deliveries within 7 days of shipment (0-1) |
| capacity_utilization   | decimal | Orders / max_capacity_units                |
| volume_tier            | varchar | Based on capacity utilization              |
| fulfillment_tier       | varchar | Performance classification                 |
| peer_fulfillment_rank  | integer | Rank within same warehouse_type (1=best)   |
| peer_count             | integer | Total warehouses of same type              |
| above_peer_avg         | boolean | Above peer group average fulfillment?      |
| peer_percentile        | decimal | Percentile within peer group (0-1)         |
| efficiency_index       | decimal | Weighted efficiency score (0-100)          |
| sla_breach_severity    | varchar | SLA breach level                           |
| operational_risk_score | decimal | Risk score (0-100)                         |

## Classification Rules

### volume_tier
Based on capacity_utilization: `high_volume` (>80%), `moderate` (40-80%), `low_volume` (10-40%), `minimal` (<10%)

### fulfillment_tier
Waterfall logic using global percentile ranking:
- `elite`: Top 25% fulfillment AND delivery_success > 95% AND on_time > 90%
- `reliable`: Above median fulfillment AND delivery_success > 80%
- `inconsistent`: Fulfillment > 60% but has delivery issues (success < 80% OR on_time < 70%)
- `struggling`: Everything else

### sla_breach_severity

Waterfall classification (check worst first, first match wins):

| Severity | Criteria                                                          |
| -------- | ----------------------------------------------------------------- |
| critical | fulfillment_rate < 0.50 OR delivery_success_rate < 0.70 OR on_time_delivery_rate < 0.50 |
| high     | fulfillment_rate < 0.70 OR delivery_success_rate < 0.80 OR on_time_delivery_rate < 0.60 |
| medium   | fulfillment_rate < 0.85 OR delivery_success_rate < 0.90 OR on_time_delivery_rate < 0.75 |
| low      | fulfillment_rate < 0.95 OR delivery_success_rate < 0.95 OR on_time_delivery_rate < 0.85 |
| none     | Default (all metrics above thresholds)                            |

### efficiency_index

Weighted composite (0-100) as a weighted sum:

| Factor           | Calculation                          | Weight |
| ---------------- | ------------------------------------ | ------ |
| fulfillment      | fulfillment_rate                     | 30%    |
| delivery_success | delivery_success_rate                | 25%    |
| on_time          | on_time_delivery_rate                | 25%    |
| shipping_speed   | 1 - (avg_ship_time_days / 14)       | 20%    |

All factors capped 0-1. Final index = weighted sum x 100, bounded 0-100.

### operational_risk_score

Composite risk metric (0-100) where higher = more risk. Weighted components:

| Risk Factor          | Weight |
| -------------------- | ------ |
| fulfillment_risk     | 35%    |
| delivery_risk        | 30%    |
| on_time_risk         | 20%    |
| shipping_speed_risk  | 15%    |

Calculate as inverse of performance (1 - rate for percentage metrics). For shipping speed, slower times increase risk.

## Requirements

- Use `PERCENT_RANK()` for percentile calculations
- Use `DENSE_RANK()` for peer ranking (1=best, descending by fulfillment_rate)
- Peer metrics must be partitioned by warehouse_type
- Handle NULL values and division by zero
- All rates bounded 0-1, scores bounded 0-100

## Guidelines
- Do NOT modify upstream staging models
- Do NOT change model materialization
- Preserve all output columns
- The SQL syntax should work on both DuckDB and Snowflake (ANSI SQL compatible)
