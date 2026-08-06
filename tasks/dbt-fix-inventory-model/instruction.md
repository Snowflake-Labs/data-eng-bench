# Fix and Enhance Product Inventory Metrics Model

## Problem

The `rpt_product_inventory_metrics` model has bugs and is missing business-critical classification logic.

## Files

- DuckDB: `/app/dbt_models_duckdb/models/marts/inventory/rpt_product_inventory_metrics.sql`
- Snowflake: `/app/dbt_models_snowflake/models/marts/inventory/rpt_product_inventory_metrics.sql`

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

## Tasks

### 1. Fix Existing Bugs

The model produces invalid values (`inf`, `nan`) in calculated metrics. Identify and fix all issues.

### 2. Add Inventory Health Tier

Add `inventory_health_tier` column using **waterfall logic** (first match wins):

| Tier          | Criteria                                                                                                    |
| ------------- | ----------------------------------------------------------------------------------------------------------- |
| `critical`  | Top 10% turnover + less than 1 week supply + has recent sales                                               |
| `at_risk`   | High stockout rate (>15%) OR low supply (<2 weeks with sales activity) OR majority of locations stocked out |
| `healthy`   | Above-median turnover + low stockout (<5%) + adequate supply (2-12 weeks)                                   |
| `overstock` | Everything else                                                                                             |

### 3. Add Velocity Score

Add `velocity_score` column (0-100 scale) combining:

- Turnover performance (40% weight): Use `PERCENT_RANK() OVER (ORDER BY turnover_ratio)` to normalize turnover to 0-1
- Sell-through efficiency (30% weight): Calculate as `units_sold_365d / NULLIF(units_sold_365d + GREATEST(total_quantity_on_hand, 0), 0)` (ratio of sold to total throughput)
- Picking recency (30% weight): Stepped function on `days_since_last_pick`:
  - <= 7 days: 1.0
  - <= 30 days: 0.7
  - <= 90 days: 0.4
  - > 90 days: 0.1

Final score: `(turnover_component + sell_through_component + recency_component) * 100`

## Expected Output

The model should include all existing columns plus:

| Column                | Type    | Description                                                |
| --------------------- | ------- | ---------------------------------------------------------- |
| inventory_health_tier | varchar | Health classification (critical/at_risk/healthy/overstock) |
| velocity_score        | decimal | Inventory velocity score (0-100)                           |

## Requirements

- Model compiles successfully
- No invalid numeric values
- All source products included in output
- Tiers distributed across multiple categories
- use PERCENT_RANK() window function for tier calculation

## Guidelines

- Do NOT use `CURRENT_DATE` for rolling window calculations (e.g., the 365-day transaction filter, days_since_last_pick, days_since_last_receipt). Instead, use `MAX(transaction_date)` from the inventory transactions table as the reference date. This ensures consistent results regardless of when the model is run.
