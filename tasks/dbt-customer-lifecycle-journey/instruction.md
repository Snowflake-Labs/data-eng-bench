# Build Customer Lifecycle Journey Analysis Model

## Business Context

The customer success team needs a lifecycle journey model to track customer progression through lifecycle stages, identify activation patterns, and predict churn risk based on journey velocity.

## Environment

- **DuckDB database**: `/app/database/retail.duckdb`
- **DuckDB dbt project**: `/app/dbt_models_duckdb`
- **Snowflake dbt project**: `/app/dbt_models_snowflake`
- **Models to create**:
  - `models/staging/customer/stg_customer__lifecycle_events.sql`
  - `models/intermediate/customer/int_customer__journey_metrics.sql`
  - `models/marts/customer/mart_customer__lifecycle_scorecard.sql`
  - `macros/calculate_journey_velocity.sql`

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

**CUSTOMER_LIFECYCLE_EVENTS**: EVENT_ID, CUSTOMER_ID, EVENT_TYPE, EVENT_DATE, EVENT_TIMESTAMP, PREVIOUS_STATUS, NEW_STATUS, EVENT_TRIGGER, EVENT_DETAILS

**CUSTOMER_SEGMENT_MEMBERS**: MEMBERSHIP_ID, CUSTOMER_ID, SEGMENT_ID, ADDED_DATE, SCORE, IS_ACTIVE

**CUSTOMER_SEGMENTS**: SEGMENT_ID, SEGMENT_CODE, SEGMENT_NAME

**int_sales__orders_enriched**: ORDER_ID, customer_id, grand_total, ordered_at, is_delivered

## Requirements

### Layer 1: Staging (`stg_customer__lifecycle_events`)

**Required Columns**:

- `customer_id`
- `first_event_date` (earliest EVENT_DATE)
- `last_event_date` (most recent EVENT_DATE)
- `total_lifecycle_events`
- `activation_date` (date of ACTIVATED or FIRST_PURCHASE event)
- `reactivation_count` (count of REACTIVATED events)
- `days_since_activation` (from activation to reference_date)
- `days_since_last_event` (from last_event_date to reference_date)
- `current_segment` (from CUSTOMER_SEGMENT_MEMBERS)
- `lifecycle_stage` (derived from event patterns - see below)
- `reference_date : max value`

**lifecycle_stage Derivation** (waterfall logic, check in order):

| Stage     | Criteria                                                  |
| --------- | --------------------------------------------------------- |
| NEW       | activation_date IS NULL (never activated)                 |
| DORMANT   | days_since_last_event > 90                                |
| AT_RISK   | days_since_last_event > 30 (and <= 90, implicitly)        |
| ACTIVE    | total_lifecycle_events >= 3 (and recently engaged)        |
| ACTIVATED | All others (has activation, < 3 events, recently engaged) |

**Note**: All stage values must be uppercase (NEW, DORMANT, AT_RISK, ACTIVE, ACTIVATED).

### Layer 2: Intermediate (`int_customer__journey_metrics`)

**Required Columns**:

- All from staging
- `journey_velocity_score` (use `calculate_journey_velocity` macro)
- `time_to_activate` (days from first event to activation)
- `events_per_month` (total_events / months_since_first)
- `orders_count` (from orders table)
- `total_order_value`
- `engagement_consistency` (events distributed evenly vs clustered)
- `avg_days_between_events`
- `activation_rate` (1 if activated, 0 if not)

### Macro: `calculate_journey_velocity`

```sql
{% macro calculate_journey_velocity(total_events, days_since_first, orders_count) %}
    -- Journey velocity 0-100 (higher = faster progression)
    -- Weights: events_frequency 40%, orders_count 35%, time_efficiency 25%
{% endmacro %}
```

### Layer 3: Mart (`mart_customer__lifecycle_scorecard`)

**Rankings**:

- `velocity_percentile` (higher journey_velocity = higher percentile; PERCENT_RANK, scale 0.0–1.0)
- `engagement_percentile` (higher events_per_month = higher percentile; PERCENT_RANK, scale 0.0–1.0)
- `value_percentile` (higher total_order_value = higher percentile; PERCENT_RANK, scale 0.0–1.0)
- `consistency_percentile` (PERCENT_RANK, scale 0.0–1.0)

**Lifecycle Health Tier** (`lifecycle_health_tier`) - waterfall classification:

Customers are classified into health tiers based on their journey metrics. The classification uses a waterfall approach where conditions are checked in order.

**thriving**: Top performers who demonstrate strong engagement across multiple dimensions. Must meet ALL of the following: top 20% velocity, significant purchase history (4+ orders), recently activated (under 120 days), and consistent engagement pattern (consistency > 0.5).

**growing**: Customers showing positive momentum. Either in the top 40% by velocity, OR have made repeat purchases (2+) with healthy engagement frequency (1.5+ events/month).

**stable**: Customers with baseline activity. Either above the 40th velocity percentile, OR have completed at least one order.

**at_risk**: Customers showing warning signs of disengagement. Identified by BOTH: extended inactivity (45+ days since last event) AND below-average velocity (bottom 30%).

**dormant**: All remaining customers who don't meet the above criteria.

**Customer Lifecycle Index** (0-100):

| Factor                  | Weight |
| ----------------------- | ------ |
| Journey velocity score  | 35%    |
| Orders count normalized | 30%    |
| Engagement consistency  | 20%    |
| Reactivation success   | 15%    |

**Churn Risk Score** (0-100, higher = more risk):

| Factor                 | Weight |
| ---------------------- | ------ |
| Days since last event  | 40%    |
| Low velocity indicator | 30%    |
| Reactivation history   | 20%    |
| Order recency          | 10%    |

**Segment Peer Comparison**:

- `segment_velocity_rank`
- `segment_peer_count`
- `above_segment_avg_velocity`
- `segment_percentile` (PERCENT_RANK, scale 0.0–1.0)

## Expected Output

The mart model columns:

- customer_id, first_event_date, last_event_date, total_lifecycle_events
- activation_date, reactivation_count, days_since_activation, days_since_last_event
- current_segment, lifecycle_stage
- time_to_activate, events_per_month, orders_count, total_order_value
- journey_velocity_score, engagement_consistency, avg_days_between_events, activation_rate
- velocity_percentile, engagement_percentile, value_percentile, consistency_percentile
- lifecycle_health_tier, customer_lifecycle_index, churn_risk_score
- segment_velocity_rank, segment_peer_count, above_segment_avg_velocity, segment_percentile

## Guidelines

- The SQL syntax should work on both DuckDB and Snowflake (ANSI SQL compatible)
