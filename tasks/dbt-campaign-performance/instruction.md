# Build Campaign Performance Analytics Model

## Overview

Create a new dbt model that analyzes marketing campaign performance by tracking email engagement, customer conversions, revenue attribution, and peer comparisons across campaign channels.

## Files

- DuckDB: `/app/dbt_models_duckdb/models/marts/marketing/rpt_campaign_performance.sql`
- Snowflake: `/app/dbt_models_snowflake/models/marts/marketing/rpt_campaign_performance.sql`

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

## Requirements

### Data Sources

Use these tables:

- `stg_marketing__campaigns` - Campaign master data (campaign_id, campaign_name, channel, start_date, end_date)
- `stg_marketing__email_events` - Email interactions (event_id, customer_id, campaign_id, event_type, event_at)
- `int_sales__orders_enriched` - Orders with customer info
  - Key columns: `ORDER_ID` (uppercase!), `customer_id`, `ordered_at`, `grand_total`, `status`
  - Exclude cancelled orders: status values include both `'CANCELLED'` and abbreviation `'C'`

### Email Event Types

The `event_type` column contains: `'SENT'`, `'OPENED'`, `'CLICKED'`, `'CONVERTED'`

### Base Metrics (per campaign)

| Metric                 | Description                                         |
| ---------------------- | --------------------------------------------------- |
| emails_sent            | Count of SENT events                                |
| emails_opened          | Count of OPENED events                              |
| emails_clicked         | Count of CLICKED events                             |
| conversions            | Count of CONVERTED events                           |
| unique_recipients      | Distinct customers with any email event             |
| open_rate              | Proportion opened (0-1)                             |
| click_rate             | Proportion clicked of opened (0-1)                  |
| conversion_rate        | Proportion converted of recipients (0-1)            |
| attributed_revenue     | Revenue from orders within 30 days after conversion |
| revenue_per_conversion | Average revenue per conversion                      |

### Channel Category Classification

Classify channels into categories based on the channel name:

| Category | Description                 |
| -------- | --------------------------- |
| PAID     | Paid advertising channels   |
| OWNED    | Owned media channels        |
| EARNED   | Earned/organic channels     |
| OTHER    | Channels not matching above |

Infer the category from keywords in the channel name.

### Peer Comparison Metrics

Compare each campaign against others in the SAME channel_category (not channel!):

| Metric                        | Description                                                         |
| ----------------------------- | ------------------------------------------------------------------- |
| category_conversion_rank      | Rank by conversion_rate within channel_category (1 = best, no gaps) |
| category_campaign_count       | Total campaigns in same channel_category                            |
| above_category_avg_conversion | 1 if above channel_category average, 0 otherwise                    |
| category_revenue_percentile   | Revenue percentile within channel_category (0-1)                    |

### Composite Score

| Metric            | Description                                                          |
| ----------------- | -------------------------------------------------------------------- |
| performance_index | Weighted composite (0-100) reflecting overall campaign effectiveness |

Formula: `(open_rate * 0.25 + click_rate * 0.25 + conversion_rate * 0.30 + revenue_efficiency * 0.20) * 100`

Where `revenue_efficiency = MIN(attributed_revenue / campaign_days / 1000) `max to 1.

### Classification

**campaign_tier** - Waterfall classification (check conditions in order, first match wins):

| Tier            | Condition                                                 |
| --------------- | --------------------------------------------------------- |
| ineffective     | conversions = 0                                           |
| underperforming | below category avg conversion AND click_rate < 0.20       |
| developing      | below category avg conversion OR click_rate < 0.40        |
| top_performer   | performance percentile >= 0.80 in category AND cvr > 0.10 |
| effective       | above category avg conversion AND performance_index >= 50 |
| developing      | default                                                   |

## Expected Output

| Column                        | Type    |
| ----------------------------- | ------- |
| campaign_id                   | varchar |
| campaign_name                 | varchar |
| channel                       | varchar |
| channel_category              | varchar |
| emails_sent                   | integer |
| emails_opened                 | integer |
| emails_clicked                | integer |
| conversions                   | integer |
| unique_recipients             | integer |
| open_rate                     | decimal |
| click_rate                    | decimal |
| conversion_rate               | decimal |
| attributed_revenue            | decimal |
| revenue_per_conversion        | decimal |
| category_conversion_rank      | integer |
| category_campaign_count       | integer |
| above_category_avg_conversion | integer |
| category_revenue_percentile   | decimal |
| performance_index             | decimal |
| campaign_tier                 | varchar |

## Validation

- Model compiles and runs successfully
- All campaigns with email events must be included
- No invalid values (infinity, NaN)
- Peer metrics partitioned by channel_category
- Scores bounded appropriately
- use `percent_rank()` and `dense_rank()` accordingly
