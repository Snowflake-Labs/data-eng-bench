# Build Email Campaign Performance Tracker Model

## Business Context

The email marketing team needs a comprehensive performance tracker to measure campaign effectiveness, identify fatigue patterns, and optimize send strategies across customer segments.

## Environment

- DuckDB: `/app/dbt_models_duckdb/models/` (dbt project: `/app/dbt_models_duckdb`)
- Snowflake: `/app/dbt_models_snowflake/models/` (dbt project: `/app/dbt_models_snowflake`)

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

- **Models to create**:
  - `models/staging/marketing/stg_marketing__email_metrics.sql`
  - `models/intermediate/marketing/int_marketing__email_performance.sql`
  - `models/marts/marketing/mart_marketing__email_scorecard.sql`
  - `macros/calculate_engagement_score.sql`

## Data Sources

**EMAIL_CAMPAIGNS**: EMAIL_CAMPAIGN_ID, CAMPAIGN_ID, SUBJECT_LINE, SENT_DATE, TOTAL_SENT, TOTAL_DELIVERED, TOTAL_OPENED, TOTAL_CLICKED

**CAMPAIGNS**: CAMPAIGN_ID, CAMPAIGN_NAME

## Requirements

### Layer 1: Staging (`stg_marketing__email_metrics`)

Calculate email performance metrics:

**Required Columns**:

- `email_campaign_id`
- `campaign_name` (from CAMPAIGNS)
- `segment_name` (use 'General' as default - segment data not linked to campaigns)
- `sent_date`
- `total_sent`
- `total_delivered`
- `total_opened`
- `total_clicked`
- `delivery_rate` (delivered / sent)
- `open_rate` (opened / delivered)
- `click_rate` (clicked / delivered)
- `click_to_open_rate` (clicked / opened)

Rates can exceed 1.0 in the source data due to multiple opens/clicks per email. Ensure your output rates are bounded to a valid range.

### Layer 2: Intermediate (`int_marketing__email_performance`)

Add engagement scoring and fatigue detection:

**Required Columns**:

- All from staging
- `engagement_score` (use `calculate_engagement_score` macro)
- `emails_sent_last_30d` (count of emails to same segment within 30-day calendar window, ORDER BY sent_date only - RANGE requires single column)
- `avg_segment_open_rate` (rolling average of last 7 rows per segment, ordered by sent_date, email_campaign_id)
- `fatigue_indicator` (1 if performance declining, 0 otherwise)

**Fatigue Logic**: open_rate < avg_segment_open_rate * 0.70 AND emails_sent_last_30d >= 4

### Macro: `calculate_engagement_score`

Create a dbt macro called `calculate_engagement_score` that takes open_rate, click_rate, and click_to_open_rate as inputs and computes a weighted engagement score on a 0-100 scale. The weights should reflect that opens matter most, followed by clicks, then click-to-open.

### Layer 3: Mart (`mart_marketing__email_scorecard`)

**Percentile Rankings** (use PERCENT_RANK with ORDER BY ASC so higher values get higher percentiles):

- `engagement_percentile` (higher engagement = higher percentile)
- `open_rate_percentile` (higher open rate = higher percentile)
- `delivery_percentile` (higher delivery rate = higher percentile)

**Performance Tier** (`performance_tier`):

| Tier      | Criteria                                                                   |
| --------- | -------------------------------------------------------------------------- |
| excellent | engagement_percentile >= 0.75 AND open_rate >= 0.25 AND click_rate >= 0.03 |
| good      | engagement_percentile >= 0.50 OR open_rate >= 0.20                         |
| average   | engagement_percentile >= 0.30 OR open_rate >= 0.15                         |
| poor      | All others                                                                 |

**Campaign Effectiveness Index** (0-100):

| Factor                                         | Weight |
| ---------------------------------------------- | ------ |
| Engagement score (normalized to 0-1)           | 40%    |
| Delivery rate                                  | 25%    |
| Open rate                                      | 20%    |
| Click rate (normalized vs median, capped at 1) | 15%    |

Formula: `(engagement_score/100 * 0.40 + delivery_rate * 0.25 + open_rate * 0.20 + MIN(1, click_rate/median_click) * 0.15) * 100`
Bound to 0-100 using LEAST/GREATEST.

**Segment Peer Comparison**:

- `segment_performance_rank`
- `segment_peer_count`
- `above_segment_avg_engagement`

## Expected Output

All metrics, percentiles, tiers, effectiveness index, segment peers
