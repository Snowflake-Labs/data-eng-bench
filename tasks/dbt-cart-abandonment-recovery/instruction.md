# Build Cart Abandonment Recovery Scoring Model

## Business Context

The e-commerce team needs a cart abandonment recovery model to prioritize outreach campaigns, predict conversion likelihood, and optimize recovery email timing.

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

## Files

- **dbt project**:
  - DuckDB: `/app/dbt_models_duckdb`
  - Snowflake: `/app/dbt_models_snowflake`
- **Models to create**:
  - `models/staging/ecommerce/_sources.yml` (define sources for ABANDONED_CARTS, WEB_SESSIONS, int_sales__orders_enriched)
  - `models/staging/ecommerce/stg_ecommerce__abandoned_carts.sql`
  - `models/intermediate/ecommerce/int_ecommerce__cart_recovery_metrics.sql`
  - `models/marts/ecommerce/mart_ecommerce__recovery_scorecard.sql`
  - `macros/calculate_recovery_priority.sql`

## Data Sources (pre-existing tables in database)

**ABANDONED_CARTS**: CART_ID, SESSION_ID, CUSTOMER_ID, ABANDONED_AT, CART_VALUE, ITEM_COUNT

**WEB_SESSIONS**: SESSION_ID, CUSTOMER_ID, SESSION_START, DURATION_SECONDS, PAGE_VIEWS, DEVICE_TYPE, UTM_SOURCE, IS_CONVERTED

**int_sales__orders_enriched** (source table, not a dbt model): ORDER_ID, customer_id, grand_total, ordered_at

## Requirements

### Layer 1: Staging (`stg_ecommerce__abandoned_carts`)

**Reference Date**: Use `MAX(ABANDONED_AT)` for recency calculations

**Required Columns**:
- `cart_id`
- `customer_id`
- `abandoned_at`
- `cart_value`
- `item_count`
- `hours_since_abandonment` (from abandoned_at to reference_date)
- `session_duration_seconds`
- `page_views`
- `device_type`
- `utm_source`
- `previous_orders_count` (customer's order history)
- `previous_order_value` (customer's total spend)

### Layer 2: Intermediate (`int_ecommerce__cart_recovery_metrics`)

**Required Columns**:
- All from staging
- `recovery_priority_score` (use `calculate_recovery_priority` macro)
- `cart_value_segment` (HIGH: >500, MEDIUM: 100-500, LOW: <100)
- `abandonment_timing` (EARLY: <1hr, RECENT: 1-24hr, STALE: 24-72hr, COLD: >72hr)
- `customer_segment` (NEW: 0 orders, RETURNING: 1-3, LOYAL: 4+)
- `engagement_level` (page_views * duration_seconds / 60)

### Macro: `calculate_recovery_priority`

```sql
{% macro calculate_recovery_priority(cart_value, item_count, hours_since, previous_orders) %}
    -- Weighted priority score 0-100
    -- Cart value: 40% (normalize by 1000)
    -- Item count: 20% (normalize by 10)
    -- Recency: 25% (normalize by 168 hours, inverted so recent = higher)
    -- Customer history: 15% (normalize by 5 orders)
{% endmacro %}
```

### Layer 3: Mart (`mart_ecommerce__recovery_scorecard`)

**Percentile Rankings**:
- `value_percentile` (higher cart_value = higher percentile)
- `recency_percentile` (lower hours_since = higher percentile - inverted!)
- `priority_percentile` (higher recovery_priority_score = higher percentile)

**Recovery Tier** (`recovery_tier`):

| Tier | Criteria |
|------|----------|
| hot_lead | priority_percentile >= 0.75 AND hours_since_abandonment < 24 AND cart_value > 200 |
| warm_lead | priority_percentile >= 0.50 OR (cart_value > 100 AND hours_since_abandonment < 48) |
| follow_up | priority_percentile >= 0.30 OR hours_since_abandonment < 72 |
| low_priority | All others |

**Conversion Likelihood Index** (0-100):

| Factor | Weight | Normalization |
|--------|--------|---------------|
| Cart value | 30% | cart_value / 1000, capped at 1 |
| Customer history | 25% | previous_orders / 10, capped at 1 |
| Engagement level | 25% | engagement_level / 300, capped at 1 |
| Recency factor | 20% | 1 - (hours_since / 168), capped 0-1 |

**Device Peer Comparison**:
- `device_recovery_rank`
- `device_peer_count`
- `above_device_avg_value`

## Expected Output

The mart model should output these columns:
- cart_id, customer_id, abandoned_at, cart_value, item_count, hours_since_abandonment
- session_duration_seconds, page_views, device_type, utm_source
- previous_orders_count, previous_order_value
- recovery_priority_score, cart_value_segment, abandonment_timing, customer_segment, engagement_level
- value_percentile, recency_percentile, priority_percentile
- recovery_tier, conversion_likelihood_index
- device_recovery_rank, device_peer_count, above_device_avg_value

## Implementation Notes

- Recency percentile inverted: recent = higher percentile
- Handle NULLs for customers without order history
- Only include carts abandoned in last 30 days
- Engagement level = page_views * duration_seconds / 60
- Window functions need tiebreaker columns for deterministic results
- Note: `int_sales__orders_enriched.customer_id` uses different case than other tables

## Guidelines
- The SQL syntax should work on both DuckDB and Snowflake (ANSI SQL compatible)
