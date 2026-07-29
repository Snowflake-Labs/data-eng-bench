# Marketing Campaigns Dimensional Model

Build intermediate and mart models for marketing analytics including campaign performance, promotion ROI, customer segmentation, channel effectiveness, and loyalty program engagement.

## Your Task

Add dbt models to the existing project that create marketing analytics dimensional models.

- DuckDB: `/app/dbt_models_duckdb/models/intermediate/marketing/` and `/app/dbt_models_duckdb/models/marts/marketing/`
- Snowflake: `/app/dbt_models_snowflake/models/intermediate/marketing/` and `/app/dbt_models_snowflake/models/marts/marketing/`

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

## Source

Use existing staging models: `stg_marketing__*` in `models/staging/marketing/`. Explore the staging tables to understand available columns.

Note: All rate and percentage fields should be stored as decimal values (0.0 to 1.0 scale), not as percentages (0 to 100 scale). For example, a 25% increase should be stored as 0.25, not 25.

## Required Models

### Intermediate Layer (models/intermediate/marketing/)

#### int_campaign_performance_summary
One row per campaign_id from stg_marketing__campaign_performance.

| Column | Description |
|--------|-------------|
| campaign_id | Group key |
| total_impressions | SUM(impressions) |
| total_clicks | SUM(clicks) |
| total_conversions | SUM(conversions) |
| total_spend | SUM(spend) |
| total_revenue | SUM(revenue) |

#### int_promotion_redemption_summary
One row per promotion_id from stg_marketing__promotion_redemptions.

| Column | Description |
|--------|-------------|
| promotion_id | Group key |
| redemption_count | COUNT(*) |
| total_discount_given | SUM(discount_amount) |

#### int_customer_rfm
One row per customer_id from combined stg_marketing__promotion_redemptions and stg_marketing__coupon_redemptions.

| Column | Description |
|--------|-------------|
| customer_id | Group key |
| recency_days | Days since most recent redemption relative to the overall most recent redemption date in the dataset (integer). Use MAX(redeemed_at) across all redemptions as the reference date, not CURRENT_DATE. |
| frequency | COUNT(*) |
| monetary | SUM(discount_amount) |
| r_score | Recency score 1-5, where 5 = most recent (equal-sized groups) |
| f_score | Frequency score 1-5, where 5 = most frequent (equal-sized groups) |
| m_score | Monetary score 1-5, where 5 = highest value (equal-sized groups) |
| rfm_segment | Segment code in format 'RFM_XXX' where X is the score (e.g. 'RFM_555') |

Score 5 = best (most recent, most frequent, highest monetary).

#### int_campaign_daily_stats
One row per campaign_id from stg_marketing__campaign_performance.

| Column | Description |
|--------|-------------|
| campaign_id | Group key |
| mean_spend | Average daily spend for this campaign |
| stddev_spend | Population standard deviation of daily spend |

#### int_channel_allocation
One row per channel_mapping_id from stg_marketing__campaign_channels.

| Column | Description |
|--------|-------------|
| channel_mapping_id | Primary key |
| campaign_id | |
| channel_type | |
| allocated_budget | |
| campaign_total_revenue | Total revenue for this campaign, default 0 |
| channel_efficiency | Revenue per dollar of allocated budget, NULL if budget is 0 |

#### int_customer_loyalty_summary
One row per customer_id from stg_marketing__loyalty_points_transactions.

| Column | Description |
|--------|-------------|
| customer_id | Group key |
| total_points_issued | Total points issued through EARN and BONUS transactions |
| total_points_redeemed | SUM(ABS(points)) for REDEEM transactions — sum of the absolute value of each REDEEM transaction's points (take the absolute value per row, then sum) |
| points_balance | Net balance of all points transactions |
| transaction_count | Total number of transactions |
| first_transaction_date | Date of first transaction |
| last_transaction_date | Date of most recent transaction |

#### int_gift_card_summary
One row per gift_card_id from stg_marketing__gift_card_transactions.

| Column | Description |
|--------|-------------|
| gift_card_id | Group key |
| total_loaded | Total amount loaded through ACTIVATION, REFUND, and ADJUSTMENT transactions |
| total_spent | Total amount spent through PURCHASE transactions (positive value) |
| net_balance | Net balance of all transactions |
| transaction_count | Total number of transactions |
| first_transaction_date | Date of first transaction |
| last_transaction_date | Date of most recent transaction |

#### int_campaign_audience_summary
One row per campaign_id from stg_marketing__campaign_audiences.

| Column | Description |
|--------|-------------|
| campaign_id | Group key |
| audience_count | Number of audience records for this campaign |
| total_audience_reach | Sum of audience sizes across all segments |
| segment_count | Number of unique segments targeted |

#### int_promotion_rule_summary
One row per promotion_id from stg_marketing__promotion_rules.

| Column | Description |
|--------|-------------|
| promotion_id | Group key |
| min_quantity_rules | Number of MIN_QUANTITY rules |
| min_amount_rules | Number of MIN_AMOUNT rules |
| category_rules | Number of CATEGORY rules |
| customer_tier_rules | Number of CUSTOMER_TIER rules |
| first_order_rules | Number of FIRST_ORDER rules |
| total_rules | Total number of rules |

#### int_customer_cohort
One row per customer_id from combined stg_marketing__promotion_redemptions and stg_marketing__coupon_redemptions.

| Column | Description |
|--------|-------------|
| customer_id | Group key |
| cohort_month | Month of first redemption (truncated to month start) |
| first_redemption_date | Date of first redemption |
| total_redemptions | Total number of redemptions |
| total_discount | Sum of all discount amounts |

#### int_campaign_rolling_metrics
One row per (campaign_id, metric_date) from stg_marketing__campaign_performance.

| Column | Description |
|--------|-------------|
| campaign_id | |
| metric_date | |
| daily_spend | spend |
| daily_revenue | revenue |
| rolling_7d_avg_spend | 7-day rolling average of daily spend for this campaign, NULL if fewer than 7 days available |
| rolling_7d_avg_revenue | 7-day rolling average of daily revenue for this campaign, NULL if fewer than 7 days available |
| days_with_data | Number of days in the rolling window |

### Marts Layer (models/marts/marketing/)

#### dim_campaigns
One row per campaign_id from stg_marketing__marketing_campaigns.

Columns: campaign_id, campaign_code, campaign_name, campaign_type, start_date, end_date, budget, status

#### dim_promotions
One row per promotion_id from stg_marketing__promotions.

Columns: promotion_id, promotion_code, promotion_name, promotion_type, discount_type, discount_value, min_purchase, max_discount, start_date, end_date, is_active

#### dim_marketing_customers
One row per customer_id.

| Column | Description |
|--------|-------------|
| customer_id | Customer ID from RFM or loyalty data |
| recency_days | NULL if no redemptions |
| frequency | Default 0 |
| monetary | Default 0 |
| r_score | NULL if no redemptions |
| f_score | NULL if no redemptions |
| m_score | NULL if no redemptions |
| rfm_segment | NULL if no redemptions |
| total_points_issued | Default 0 |
| total_points_redeemed | Default 0 |
| points_balance | Default 0 |
| has_loyalty_activity | TRUE if customer has any loyalty points transactions |
| has_redemption_activity | TRUE if customer has any promotion or coupon redemptions |

#### dim_loyalty_programs
One row per program_id from stg_marketing__loyalty_programs.

Columns: program_id, program_name, program_type, points_per_dollar, points_value, is_active

#### dim_gift_cards
One row per gift_card_id from stg_marketing__gift_cards.

Columns: gift_card_id, card_number, initial_value, current_balance, currency_code, status, purchased_by, activated_at, expires_at

#### fct_campaign_daily_performance
One row per (campaign_id, metric_date) from stg_marketing__campaign_performance.

| Column | Description |
|--------|-------------|
| campaign_id | |
| campaign_code | NULL if campaign not found |
| campaign_name | NULL if campaign not found |
| metric_date | |
| impressions | |
| clicks | |
| conversions | |
| spend | |
| revenue | |
| ctr | Click-through rate (clicks divided by impressions), NULL if no impressions |
| conversion_rate | Conversion rate (conversions divided by clicks), NULL if no clicks |
| roas | Return on ad spend (revenue divided by spend), NULL if no spend |
| is_anomalous | TRUE if CTR exceeds 50%, conversion rate exceeds 80%, or daily spend is more than 3 standard deviations above campaign average |

#### fct_campaign_performance
One row per campaign_id from stg_marketing__marketing_campaigns.

| Column | Description |
|--------|-------------|
| campaign_id | |
| campaign_code | |
| campaign_name | |
| campaign_type | |
| status | |
| budget | |
| total_impressions | Default 0 |
| total_clicks | Default 0 |
| total_conversions | Default 0 |
| total_spend | Default 0 |
| total_revenue | Default 0 |
| ctr | Click-through rate, NULL if no impressions |
| conversion_rate | Conversion rate, NULL if no clicks |
| roas | Return on ad spend, NULL if no spend |
| cpa | Cost per acquisition (total spend divided by conversions), NULL if no conversions |
| budget_utilization | Budget utilization rate (spend divided by budget), NULL if no budget |
| effectiveness_score | Weighted composite score: ROAS x 0.4 + conversion_rate x 100 x 0.3 + CTR x 100 x 0.2 + budget_utilization x 0.1, NULL if ROAS is NULL |
| roas_percentile | Percentile rank of this campaign's ROAS (0.0 to 1.0) |
| ctr_percentile | Percentile rank of this campaign's CTR (0.0 to 1.0) |
| conversion_rate_percentile | Percentile rank of this campaign's conversion rate (0.0 to 1.0) |
| cumulative_revenue | Running total of revenue across all campaigns ordered by campaign_id |

#### fct_promotion_performance
One row per promotion_id from stg_marketing__promotions.

| Column | Description |
|--------|-------------|
| promotion_id | |
| promotion_code | |
| promotion_name | |
| promotion_type | |
| discount_type | |
| is_active | |
| redemption_count | Default 0 |
| total_discount_given | Default 0 |
| avg_discount_per_redemption | Average discount per redemption, NULL if no redemptions |
| customer_reach | Number of unique customers who redeemed this promotion, 0 if none |

#### fct_campaign_weekly_performance
One row per (campaign_id, week_start). Aggregate stg_marketing__campaign_performance by campaign_id and DATE_TRUNC('week', metric_date).

| Column | Description |
|--------|-------------|
| campaign_id | Group key |
| campaign_name | |
| week_start | DATE_TRUNC('week', metric_date) |
| weekly_impressions | SUM(impressions) |
| weekly_clicks | SUM(clicks) |
| weekly_conversions | SUM(conversions) |
| weekly_spend | SUM(spend) |
| weekly_revenue | SUM(revenue) |
| weekly_roas | Weekly return on ad spend, NULL if no spend |
| prior_week_revenue | Previous week's revenue for this campaign, NULL for first week |
| wow_revenue_change | Week-over-week revenue change percentage, NULL if no prior week |
| running_total_revenue | Cumulative revenue for this campaign from first week to current |

#### fct_campaign_monthly_performance
One row per (campaign_id, month_start). Aggregate stg_marketing__campaign_performance by campaign_id and DATE_TRUNC('month', metric_date).

| Column | Description |
|--------|-------------|
| campaign_id | Group key |
| campaign_name | |
| month_start | DATE_TRUNC('month', metric_date) |
| monthly_impressions | SUM(impressions) |
| monthly_clicks | SUM(clicks) |
| monthly_conversions | SUM(conversions) |
| monthly_spend | SUM(spend) |
| monthly_revenue | SUM(revenue) |
| monthly_roas | Monthly return on ad spend, NULL if no spend |
| prior_month_revenue | Previous month's revenue for this campaign, NULL for first month |
| mom_revenue_change | Month-over-month revenue change percentage, NULL if no prior month |
| ytd_revenue | Year-to-date revenue for this campaign (resets each year) |
| ytd_spend | Same window |
| ytd_conversions | Same window |

#### fct_loyalty_performance
One row per program_id from stg_marketing__loyalty_programs.

| Column | Description |
|--------|-------------|
| program_id | |
| program_name | |
| program_type | |
| is_active | |
| total_members | Number of unique customers in this program |
| total_points_issued | Total points issued through EARN and BONUS transactions |
| total_points_redeemed | Total points redeemed (positive value) |
| total_points_outstanding | Net outstanding points balance |
| redemption_rate | Redemption rate (redeemed divided by issued), NULL if no points issued |
| points_value_issued | Dollar value of issued points (points x program point value) |
| points_value_redeemed | Dollar value of redeemed points (points x program point value) |

#### fct_gift_card_performance
One row per gift_card_id from stg_marketing__gift_cards.

| Column | Description |
|--------|-------------|
| gift_card_id | |
| card_number | |
| initial_value | |
| current_balance | |
| status | |
| total_loaded | Default 0 |
| total_spent | Default 0 |
| utilization_rate | Utilization rate (spent divided by loaded), NULL if nothing loaded |
| transaction_count | Default 0 |
| is_fully_redeemed | TRUE if current_balance = 0 AND total_spent > 0 |

#### fct_campaign_audience_performance
One row per campaign_id from stg_marketing__marketing_campaigns.

| Column | Description |
|--------|-------------|
| campaign_id | |
| campaign_code | |
| campaign_name | |
| budget | |
| total_spend | Default 0 |
| total_revenue | Default 0 |
| total_audience_reach | Default 0 |
| audience_count | Default 0 |
| cost_per_audience_member | Average spend per audience member, NULL if no audience |
| revenue_per_audience_member | Average revenue per audience member, NULL if no audience |

#### bridge_campaign_channel
One row per channel_mapping_id from stg_marketing__campaign_channels.

| Column | Description |
|--------|-------------|
| channel_mapping_id | |
| campaign_id | |
| channel_type | |
| allocated_budget | |
| campaign_total_revenue | Default 0 |
| channel_efficiency | Channel efficiency (revenue divided by allocated budget), NULL if no budget |

#### fct_promotion_rule_analysis
One row per promotion_id from stg_marketing__promotions.

| Column | Description |
|--------|-------------|
| promotion_id | |
| promotion_code | |
| promotion_name | |
| redemption_count | Default 0 |
| total_discount_given | Default 0 |
| total_rules | Default 0 |
| rule_complexity_score | Weighted complexity: min_quantity x 1 + min_amount x 2 + category x 1 + customer_tier x 3 + first_order x 2, default 0 |
| avg_discount_per_rule | Average discount per rule, NULL if no rules |

#### fct_customer_cohort_performance
One row per cohort_month.

| Column | Description |
|--------|-------------|
| cohort_month | Group key |
| cohort_size | Number of unique customers in this cohort |
| total_redemptions | Total redemptions across all customers in cohort |
| total_discount | Total discount amount across all customers in cohort |
| avg_redemptions_per_customer | Average redemptions per customer in cohort |
| avg_discount_per_customer | Average discount per customer in cohort |
| retention_rate_month_1 | See below |
| retention_rate_month_2 | See below |
| retention_rate_month_3 | See below |

Retention: Percentage of cohort customers who made at least one redemption in month N after their cohort month, where N is 1, 2, or 3 months.

#### fct_campaign_trend_analysis
One row per (campaign_id, metric_date) from stg_marketing__campaign_performance.

| Column | Description |
|--------|-------------|
| campaign_id | |
| campaign_name | |
| metric_date | |
| daily_spend | spend |
| daily_revenue | revenue |
| rolling_7d_avg_spend | |
| rolling_7d_avg_revenue | |
| spend_trend | See below |
| revenue_trend | See below |

Trend: Compare to previous day's rolling average value.
- 'UP' if current exceeds prior by more than 5%
- 'DOWN' if current is below prior by more than 5%
- 'STABLE' if within 5% of prior
- NULL if no prior value or prior is 0

## Guidelines

- The SQL syntax should work on both DuckDB and Snowflake (ANSI SQL compatible)
- Use `NULLIF()` to prevent division by zero
- Use `COALESCE()` for default values
- Use `CAST(x AS DOUBLE)` or multiply by `1.0` for division precision where needed
