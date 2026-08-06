# Advanced Multi-Model Time-Decay Attribution Analysis

Build a comprehensive marketing attribution system with multiple decay models, multi-touch customer journey analysis, and confidence scoring.

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
- Create a `profiles.yml` in the dbt project directory with profile name `attribution_project`
- Set `DBT_PROFILES_DIR` environment variable to the directory containing `profiles.yml`

### DuckDB Profile
Configure with `type: duckdb` and the database path from `$DUCKDB_PATH`.

### Snowflake Profile
Configure with `type: snowflake` using password authentication:
- Use the environment variables for account, user, password, database, schema, warehouse, and role

## Data Sources

- `MARKETING.CAMPAIGN_PERFORMANCE` - Daily campaign metrics (impressions, clicks, conversions, spend, revenue)
- `MARKETING.MARKETING_CAMPAIGNS` - Campaign metadata (campaign_id, campaign_type, status, start_date, end_date)
- `MARKETING.CAMPAIGN_CHANNELS` - Campaign channel allocations (campaign_id, channel_type)
- `ORDERS.ORDERS` - Order data for customer journey analysis

## Requirements

Create a dbt project at `/app/attribution_project` with schema `attribution_analytics`.

Note: models must land in a schema named **exactly** `attribution_analytics` (not prefixed). dbt prepends the target schema to custom schema names by default (e.g. `main_attribution_analytics` on DuckDB), so override the `generate_schema_name` macro so all models are created in `attribution_analytics` exactly, on both DuckDB and Snowflake.

### Model 1: Three Decay Models
Build `decay_model_comparison` implementing three attribution models:

1. **Exponential Decay**: `weight = 2^(-days_ago / half_life)`
   - Use `half_life = 7` days

2. **Linear Decay**: `weight = max(0, 1 - (days_ago / lookback_window))`
   - Linearly decreasing from 1.0 to 0.0 over the window

3. **Position-Based (U-Shaped)**:
   - First touchpoint: 40% weight
   - Last touchpoint: 40% weight
   - Middle touchpoints: split remaining 20% equally

**Parameters:**
- Reference (as-of) date: use the **most recent date in the data** — `MAX(metric_date)` for the decay models and `MAX(ordered_at)` for journeys. Do **NOT** use `CURRENT_DATE` (the data may not extend to the present day).
- Lookback window: 30 days (exclude data older than 30 days before the reference date)

For each campaign, calculate per-model:
- `exponential_revenue`, `linear_revenue`, `position_revenue`
- `exponential_conversions`, `linear_conversions`, `position_conversions`

### Model 2: Customer Journey Attribution
Build `customer_journey_attribution` that:

1. **Construct customer journeys** from ORDERS:
   - For each customer, track their sequence of orders by ORDERED_AT
   - Map orders to campaigns via `CHANNEL_ID` using a **LEFT JOIN** to `CAMPAIGN_CHANNELS` (on `channel_type`). **Note:** `ORDERS.CHANNEL_ID` values may not exist in `CAMPAIGN_CHANNELS` at all — so use a LEFT JOIN and **keep every in-window order**, labeling unmatched orders' `campaign_id` as `'UNKNOWN'`. Do NOT inner-join (that would drop all orders and yield an empty result). Every order must still contribute to `journey_attributed_revenue`, `unique_customers`, and `avg_journey_length`.
   - Only include orders within the 30-day lookback window ending at the reference date (`MAX(ordered_at)` in the data — not `CURRENT_DATE`)

2. **Apply position-based attribution to journeys**:
   - First order in journey: 40% of that order's value
   - Last order in journey: 40% of that order's value
   - Middle orders: split 20% equally
   - Single-order journeys: 100% to that touchpoint

3. **Aggregate by campaign**:
   - `journey_attributed_revenue` - Total revenue from journey attribution
   - `unique_customers` - Count of unique customers touched
   - `avg_journey_length` - Average number of touchpoints in customer journeys

### Model 3: Channel Interaction Analysis
Build `channel_interaction_effects` that analyzes how channels work together:

1. **Identify channel pairs** that appear together in the same customer journey
2. **Calculate interaction lift**:
   - For each channel pair (A, B): `lift = actual_combined_revenue / expected_revenue`
   - `expected_revenue = revenue_with_A_only + revenue_with_B_only`
3. **Flag synergy**: `has_synergy = true` if lift > 1.1 (10% synergy threshold)

### Model 4: Attribution Confidence Scoring
Build `attribution_confidence` that calculates confidence in attribution:

1. **Sample size factor**: `sqrt(num_touchpoints / 100)` capped at 1.0
2. **Recency factor**: Higher confidence for more recent data
   - `recency_score = avg(weight)` from exponential decay
3. **Consistency factor**: How consistent are results across decay models
   - `consistency = max(0, 1 - (stddev(model_revenues) / avg(model_revenues)))` — floor at 0 so a highly-variable channel (stddev > avg) cannot produce a negative consistency (and therefore never a negative `confidence_score`)
4. **Final confidence**: `confidence_score = (sample_factor * 0.3 + recency_score * 0.3 + consistency * 0.4) * 100`

### Edge Cases
- Campaigns with no performance data in lookback: exclude from decay_model_comparison
- Campaigns with no channel mapping: use campaign_type from MARKETING_CAMPAIGNS as fallback
- Customers with single touchpoint: 100% attribution to that touchpoint
- Channel pairs with <5 shared customers: exclude from interaction analysis
- Division by zero in consistency: set consistency to 0 if avg is 0

## Output Models

**decay_model_comparison** (in `attribution_analytics` schema):
`campaign_id`, `channel`, `exponential_revenue`, `linear_revenue`, `position_revenue`, `exponential_conversions`, `linear_conversions`, `position_conversions`, `touchpoint_count`, `total_weight`

**customer_journey_attribution**:
`campaign_id`, `channel`, `journey_attributed_revenue`, `unique_customers`, `avg_journey_length`, `first_touch_revenue`, `last_touch_revenue`, `middle_touch_revenue`

**channel_interaction_effects**:
`channel_a`, `channel_b`, `shared_customers`, `combined_revenue`, `expected_revenue`, `interaction_lift`, `has_synergy`

**attribution_confidence**:
`campaign_id`, `channel`, `sample_factor`, `recency_score`, `consistency_score`, `confidence_score`

## Guidelines
- Do NOT modify source data
- Preserve all output columns as specified
