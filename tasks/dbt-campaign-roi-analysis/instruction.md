# Build Marketing Campaign ROI Analysis Model

## Business Context

The marketing team needs a comprehensive ROI analysis model that attributes revenue to campaigns using multi-touch attribution logic. They want to understand which campaigns and channels are most effective at driving conversions.

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

### Schema Routing

All models must materialize in the `main` schema on Snowflake. Configure your dbt profile with `schema: main`. You must also override the `generate_schema_name` macro so that dbt places all models directly in the target schema defined in profiles.yml, ignoring any custom schema config from subdirectory placement. Create `macros/generate_schema_name.sql` with:

```sql
{% macro generate_schema_name(custom_schema_name, node) -%}
    {{ default_schema }}
{%- endmacro %}
```

This ensures models in `models/staging/marketing/` still land in `main`, not `main_marketing`.

## Environment

- **dbt project**:
  - DuckDB: `/app/dbt_models_duckdb`
  - Snowflake: `/app/dbt_models_snowflake`
- **Models to create**:
  - `models/staging/marketing/stg_marketing__campaigns.sql`
  - `models/intermediate/marketing/int_marketing__attributed_conversions.sql`
  - `models/marts/marketing/mart_marketing__campaign_roi.sql`
  - `macros/calculate_roas.sql`

## Data Sources

Explore the following tables to understand available columns:

- **CAMPAIGNS** - Campaign master data including identifiers, names, channels, date ranges, budgets, and status
- **CAMPAIGN_PERFORMANCE** - Daily campaign metrics including spend, impressions, clicks, conversions, and revenue
- **WEB_SESSIONS** - Web session data with customer, campaign attribution (UTM), conversion status, and order linkage
- **CONVERSIONS** - Conversion records with session linkage, customer, value, and attribution details
- **int_sales__orders_enriched** (pre-existing dbt model in main schema) - Enriched orders with totals, dates, status, and delivery information

## Requirements

Create a multi-layer model architecture to analyze campaign ROI:

### Layer 1: Staging (`stg_marketing__campaigns`)

Clean and prepare campaign data:

**Required Columns**:
- `campaign_id`
- `campaign_name`
- `channel` (uppercase)
- `start_date`
- `end_date`
- `total_budget`
- `total_spend` (sum of SPEND from CAMPAIGN_PERFORMANCE)
- `total_impressions` (sum from CAMPAIGN_PERFORMANCE)
- `total_clicks` (sum from CAMPAIGN_PERFORMANCE)
- `is_active` (1 if STATUS = 'ACTIVE', else 0)

Aggregate performance metrics per campaign from CAMPAIGN_PERFORMANCE table.

### Layer 2: Intermediate (`int_marketing__attributed_conversions`)

Implement multi-touch attribution logic:

**Attribution Rules** (per conversion, may create multiple rows):
- **Multi-Touch** (1 row, weight 1.0): Same campaign in customer's first session AND converting session
- **Split Touch** (2 rows, weight 0.5 each): Different campaigns
  - **First Touch**: Campaign from customer's first session (if exists)
  - **Last Touch**: Campaign from converting session
- **Last Touch Only** (1 row, weight 0.5): No campaign in first session, only converting session

**Required Columns**:
- `conversion_id`
- `campaign_id` (campaign receiving attribution for this row)
- `customer_id`
- `session_id` (converting session)
- `conversion_value` (from CONVERSIONS.VALUE)
- `order_value` (from orders table: grand_total)
- `attribution_type` (text: 'first_touch', 'last_touch', 'multi_touch')
- `attribution_weight` (numeric: 0.5 for first/last only, 1.0 for multi-touch)
- `attributed_revenue` (order_value * attribution_weight)

**Join Logic**:
- Link WEB_SESSIONS to CONVERSIONS via SESSION_ID
- Link WEB_SESSIONS to orders via ORDER_ID (WEB_SESSIONS.ORDER_ID)
- Only include delivered orders (is_delivered = true/1)
- Determine first campaign per customer: campaign from first session with UTM_CAMPAIGN
- One conversion may generate 1-2 attribution rows depending on campaign overlap

### Layer 3: Mart (`mart_marketing__campaign_roi`)

Calculate ROI metrics and performance tiers:

**Base Metrics**:
- `campaign_id`
- `campaign_name`
- `channel`
- `total_budget`
- `total_spend`
- `total_impressions`
- `total_clicks`
- `total_attributed_conversions` (count of distinct conversions)
- `total_attributed_revenue` (sum of attributed_revenue)

**Efficiency Metrics** (use `calculate_roas` macro):
- `roas` (Return on Ad Spend: attributed_revenue / spend)
- `ctr` (Click-Through Rate: clicks / impressions * 100)
- `cpc` (Cost Per Click: spend / clicks)
- `cpa` (Cost Per Acquisition: spend / conversions)
- `revenue_per_impression` (attributed_revenue / impressions)

**Percentile Rankings** (use PERCENT_RANK):
- `roas_percentile` (higher ROAS = higher percentile)
- `cpa_percentile` (lower CPA = higher percentile - inverted!)
- `ctr_percentile` (higher CTR = higher percentile)

**ROI Performance Tier** (`roi_tier`):

Waterfall logic (check in order):

| Tier | Criteria |
|------|----------|
| high_performer | roas_percentile >= 0.75 AND roas >= 3.0 AND cpa < 50 |
| profitable | roas_percentile >= 0.60 OR roas >= 2.0 |
| break_even | roas >= 1.0 OR roas_percentile >= 0.40 |
| underperforming | All others |

**NULL Handling**: Treat NULL percentiles as 0, NULL ROAS as 0, NULL CPA as 999.

**Campaign Effectiveness Index** (0-100):

A composite score combining:

| Factor | Weight | Calculation |
|--------|--------|-------------|
| ROAS normalized | 40% | `min(1.0, max(0, roas / 5.0))` |
| CTR normalized | 25% | `min(1.0, max(0, ctr / 5.0))` |
| CPA efficiency | 20% | `1.0 - min(1.0, max(0, cpa / 100.0))` |
| Revenue/impression ratio | 15% | `min(1.0, max(0, revenue_per_impression / median_revenue_per_impression))` |

Formula: `(factor1 * 0.40 + factor2 * 0.25 + factor3 * 0.20 + factor4 * 0.15) * 100`

Final score bounded 0-100.

**Channel Peer Comparison Metrics**:

Compare campaigns within the same channel:

| Column | Description |
|--------|-------------|
| channel_roi_rank | Rank within channel by ROAS (best = 1) |
| channel_peer_count | Total campaigns in this channel |
| above_channel_avg_roas | 1 if roas > avg for channel, else 0 |

### Macro: `calculate_roas`

Create a reusable macro for ROAS calculation:

```sql
{% macro calculate_roas(revenue, spend, min_spend_threshold=1) %}
    -- Return ROAS (revenue / spend)
    -- If spend < min_spend_threshold, return 0
    -- Handle division by zero
{% endmacro %}
```

## Expected Output (mart_marketing__campaign_roi)

Required columns:
- `campaign_id`
- `campaign_name`
- `channel`
- `total_budget`
- `total_spend`
- `total_impressions`
- `total_clicks`
- `total_attributed_conversions`
- `total_attributed_revenue`
- `roas`
- `ctr`
- `cpc`
- `cpa`
- `revenue_per_impression`
- `roas_percentile`
- `cpa_percentile`
- `ctr_percentile`
- `roi_tier`
- `campaign_effectiveness_index`
- `channel_roi_rank`
- `channel_peer_count`
- `above_channel_avg_roas`

## Implementation Notes

- Only include campaigns with total_spend > 0
- Handle division by zero in all metrics using NULLIF or the macro
- CPA percentile must be INVERTED: lower CPA = higher percentile
- Use window functions for customer's first session detection
- Attribution weights should sum correctly (0.5 + 0.5 = 1.0 for split attribution)
- Ensure all numeric columns avoid infinity and NaN values
- The staging and intermediate layers must build correctly before the mart layer runs

## Guidelines

- The SQL syntax should work on both DuckDB and Snowflake (ANSI SQL compatible)
