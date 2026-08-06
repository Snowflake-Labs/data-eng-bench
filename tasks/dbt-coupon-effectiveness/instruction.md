# Coupon Effectiveness Analysis

Build a comprehensive coupon and promotion effectiveness analytics suite that measures redemption rates, discount impact, revenue lift, and customer acquisition metrics. This includes analyzing promotion performance, comparing discount strategies, tracking temporal trends, and identifying high-value promotions.

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

- DuckDB dbt project: `/app/dbt_transforms`
- Snowflake dbt project: `/app/dbt_models_snowflake`
- Analysis date: December 1, 2024
- Analysis period: January 1, 2023 through November 30, 2024

## Source Data

The staging layer provides:

- `stg_pos__promotions`: promotion_id, promotion_code, promotion_name, promotion_type, discount_type, discount_value, min_purchase, max_discount, start_date, end_date, is_active
- `stg_pos__coupons`: coupon_id, coupon_code, promotion_id, usage_limit, usage_count, is_active, expires_at
- `stg_pos__coupon_usage`: redemption_id, coupon_id, order_id, customer_id, discount_amount, redeemed_at
- `stg_orders__orders`: order_id, customer_id, ordered_at, grand_total, status, test_order_flag, is_first_order

## Requirements

### Data Rules

Only include orders that are:
- Status is not CANCELLED, RETURNED, or FAILED
- Not a test order (test_order_flag is not 1 or true)
- Within the analysis period (ordered_at >= '2023-01-01' and ordered_at < '2024-12-01')

Only include redemptions where:
- The associated order is valid (as defined above)
- discount_amount > 0

### Models to Create

Create these dbt models:

1. **Intermediate models** in `models/intermediate/`:
   - `int_coupon_redemptions`: Join coupon usage with coupons, promotions, and orders to create a unified redemption view with all relevant details.

2. **Mart models** in `models/marts/analytics/`:
   - `coupon_effectiveness`: Promotion-level effectiveness metrics (table)
   - `coupon_summary`: Summary by promotion type and discount type (table)
   - `coupon_trends`: Monthly redemption trends per promotion (table)

### Effectiveness Metrics

For each promotion, calculate:

**Redemption Metrics:**
- **total_coupons**: Count of distinct coupons associated with this promotion
- **total_redemptions**: Count of redemptions (coupon usages)
- **unique_customers**: Count of distinct customers who redeemed
- **unique_orders**: Count of distinct orders with redemptions
- **repeat_redeemer_count**: Customers who redeemed more than once
- **repeat_redeemer_pct**: Percentage of customers who are repeat redeemers

**Financial Metrics:**
- **total_discount_given**: Sum of discount_amount from all redemptions
- **total_order_value**: Sum of grand_total from orders with redemptions
- **total_order_value_before_discount**: total_order_value + total_discount_given
- **avg_discount_per_redemption**: total_discount_given / total_redemptions
- **avg_order_value**: total_order_value / unique_orders
- **avg_order_value_before_discount**: total_order_value_before_discount / unique_orders
- **discount_to_revenue_ratio**: total_discount_given / total_order_value (as percentage)
- **revenue_per_discount_dollar**: total_order_value / total_discount_given

**Usage Metrics:**
- **total_usage_limit**: Sum of usage_limit across all coupons for this promotion (NULL if any coupon has no limit)
- **redemption_rate**: total_redemptions / total_usage_limit x 100 (NULL if unlimited)
- **avg_redemptions_per_coupon**: total_redemptions / total_coupons
- **avg_redemptions_per_customer**: total_redemptions / unique_customers

**Customer Acquisition:**
- **first_time_redemptions**: Redemptions from orders where is_first_order = true/1
- **repeat_redemptions**: Redemptions from repeat customer orders
- **first_time_pct**: Percentage of redemptions from first-time buyers
- **new_customer_acquisition_cost**: Sum of discount_amount from first-time order redemptions / first_time_redemptions (NULL if 0 first-timers). This measures the average discount given per first-time customer acquisition.

**Customer Concentration Risk:**

Analyze how dependent a promotion's success is on a small number of customers:

- **top_customer_redemptions**: Count of redemptions from the top 10% of customers (by redemption count per customer for this promotion). Calculate by: ranking customers by their redemption count for this promotion, identifying the top 10% (use CEIL(unique_customers * 0.1) to get the count of top customers), and summing their redemptions.
- **top_customer_pct**: top_customer_redemptions / total_redemptions x 100
- **single_use_customer_count**: Count of customers who redeemed exactly once for this promotion
- **single_use_customer_pct**: single_use_customer_count / unique_customers x 100
- **concentration_risk**: Classification based on top_customer_pct:
  - 'High': top_customer_pct >= 50%
  - 'Medium': top_customer_pct >= 30% and < 50%
  - 'Low': top_customer_pct < 30%

### Promotion Classification

**Performance Tier** based on total_order_value:
- 'High Performer': Top 20% by total_order_value
- 'Medium Performer': Middle 60%
- 'Low Performer': Bottom 20%

**Efficiency Rating** based on revenue_per_discount_dollar:
- 'Excellent': revenue_per_discount_dollar >= 10
- 'Good': revenue_per_discount_dollar >= 5 and < 10
- 'Average': revenue_per_discount_dollar >= 2 and < 5
- 'Poor': revenue_per_discount_dollar < 2

**Customer Focus** based on first_time_pct:
- 'Acquisition': first_time_pct >= 50%
- 'Retention': first_time_pct < 30%
- 'Balanced': otherwise

### Temporal Analysis

For each promotion, calculate using `ordered_at` (the order timestamp) as the date source:
- **first_redemption_date**: Date of first redemption (min of ordered_at cast to date)
- **last_redemption_date**: Date of most recent redemption (max of ordered_at cast to date)
- **days_active**: Days between first and last redemption (minimum 1, even for same-day promotions)
- **avg_daily_redemptions**: total_redemptions / days_active

**Activity Status:**
- 'Active': last_redemption_date within last 30 days of analysis date (>= 2024-11-01)
- 'Dormant': last_redemption_date between 31-90 days ago (>= 2024-09-02 and < 2024-11-01)
- 'Inactive': last_redemption_date more than 90 days ago (< 2024-09-02)

### Promotion Effectiveness Decay

Measure whether a promotion's effectiveness changes over its lifecycle by comparing the first half of redemptions to the second half:

1. For each promotion, assign a row number to each redemption ordered by `ordered_at` (use deterministic ordering: `ordered_at, redemption_id`)
2. Split redemptions into two halves:
   - **Early half**: redemptions where row_number <= CEIL(total_redemptions / 2)
   - **Late half**: redemptions where row_number > CEIL(total_redemptions / 2)
3. Calculate metrics for each half:
   - **early_redemption_count**: Count of redemptions in early half
   - **late_redemption_count**: Count of redemptions in late half
   - **early_avg_order_value**: Average grand_total for early half redemptions
   - **late_avg_order_value**: Average grand_total for late half redemptions
   - **early_avg_discount**: Average discount_amount for early half redemptions
   - **late_avg_discount**: Average discount_amount for late half redemptions
4. Calculate decay metrics:
   - **order_value_decay_pct**: ((early_avg_order_value - late_avg_order_value) / early_avg_order_value) x 100. Positive means declining, negative means improving.
   - **decay_classification**: Based on order_value_decay_pct:
     - 'Improving': order_value_decay_pct < -10 (late is better)
     - 'Stable': order_value_decay_pct >= -10 and <= 10
     - 'Declining': order_value_decay_pct > 10 and <= 30
     - 'Collapsing': order_value_decay_pct > 30

Note: For promotions with only 1 redemption, set early/late counts to 1/0, early metrics to the single redemption values, late metrics to NULL, order_value_decay_pct to NULL, and decay_classification to 'Stable'.

### Rounding Rules

- Round monetary values to 2 decimal places
- Round percentages to 1 decimal place
- Round ratios to 2 decimal places
- Round averages to 2 decimal places

## Output: coupon_effectiveness

| Column | Type | Description |
|--------|------|-------------|
| promotion_id | string | Promotion identifier |
| promotion_name | string | Promotion name |
| promotion_type | string | Type of promotion |
| discount_type | string | Type of discount (percentage, fixed, etc.) |
| discount_value | decimal | Configured discount value |
| total_coupons | integer | Coupons under this promotion |
| total_redemptions | integer | Total times redeemed |
| unique_customers | integer | Distinct customers |
| unique_orders | integer | Distinct orders |
| repeat_redeemer_count | integer | Customers who redeemed 2+ times |
| repeat_redeemer_pct | decimal(1) | Percent repeat redeemers |
| total_discount_given | decimal(2) | Sum of discounts |
| total_order_value | decimal(2) | Sum of order values |
| total_order_value_before_discount | decimal(2) | Order value + discount |
| avg_discount_per_redemption | decimal(2) | Average discount |
| avg_order_value | decimal(2) | Average order value |
| avg_order_value_before_discount | decimal(2) | Avg order before discount |
| discount_to_revenue_ratio | decimal(1) | Discount as % of revenue |
| revenue_per_discount_dollar | decimal(2) | Revenue generated per $1 discount |
| total_usage_limit | integer | Sum of coupon limits (NULL if unlimited) |
| redemption_rate | decimal(1) | Percent of limit used (NULL if unlimited) |
| avg_redemptions_per_coupon | decimal(2) | Avg redemptions per coupon |
| avg_redemptions_per_customer | decimal(2) | Avg redemptions per customer |
| first_time_redemptions | integer | Redemptions from new customers |
| repeat_redemptions | integer | Redemptions from repeat customers |
| first_time_pct | decimal(1) | Percent from first-time buyers |
| new_customer_acquisition_cost | decimal(2) | Cost per new customer (NULL if none) |
| first_redemption_date | date | First redemption date |
| last_redemption_date | date | Last redemption date |
| days_active | integer | Days between first and last (minimum 1) |
| avg_daily_redemptions | decimal(2) | Average daily redemptions |
| activity_status | string | Active/Dormant/Inactive |
| performance_tier | string | High/Medium/Low Performer |
| efficiency_rating | string | Excellent/Good/Average/Poor |
| customer_focus | string | Acquisition/Retention/Balanced |
| revenue_rank | integer | Rank by total_order_value (1 = highest) |
| top_customer_redemptions | integer | Redemptions from top 10% customers |
| top_customer_pct | decimal(1) | Percent of redemptions from top 10% |
| single_use_customer_count | integer | Customers who redeemed once |
| single_use_customer_pct | decimal(1) | Percent single-use customers |
| concentration_risk | string | High/Medium/Low |
| early_redemption_count | integer | Redemptions in first half |
| late_redemption_count | integer | Redemptions in second half |
| early_avg_order_value | decimal(2) | Avg order value in first half |
| late_avg_order_value | decimal(2) | Avg order value in second half (NULL if 1 redemption) |
| early_avg_discount | decimal(2) | Avg discount in first half |
| late_avg_discount | decimal(2) | Avg discount in second half (NULL if 1 redemption) |
| order_value_decay_pct | decimal(1) | Percent decay in order value (NULL if 1 redemption) |
| decay_classification | string | Improving/Stable/Declining/Collapsing |

Order by revenue_rank ASC.

## Output: coupon_summary

Summary aggregated by promotion_type and discount_type.

| Column | Type | Description |
|--------|------|-------------|
| promotion_type | string | Type of promotion |
| discount_type | string | Type of discount |
| promotion_count | integer | Number of promotions |
| total_redemptions | integer | Total redemptions |
| unique_customers | integer | Distinct customers |
| total_discount_given | decimal(2) | Sum of discounts |
| total_order_value | decimal(2) | Sum of order values |
| avg_discount_per_redemption | decimal(2) | Average discount |
| avg_order_value | decimal(2) | Average order value |
| revenue_per_discount_dollar | decimal(2) | Revenue per $1 discount |
| first_time_pct | decimal(1) | Percent from first-time buyers |
| pct_of_total_redemptions | decimal(1) | Percent of all redemptions |
| pct_of_total_revenue | decimal(1) | Percent of all coupon revenue |
| high_performer_count | integer | Count of high performers |
| excellent_efficiency_count | integer | Count with excellent efficiency |

Order by total_order_value DESC.

## Output: coupon_trends

Monthly breakdown of redemption patterns per promotion. Group by month using the order date (`ordered_at`), formatted as 'YYYY-MM'.

**Weekday/Weekend Analysis:**
For each month, also calculate weekday vs weekend performance:
- Weekday: Monday through Friday
- Weekend: Saturday and Sunday

| Column | Type | Description |
|--------|------|-------------|
| promotion_id | string | Promotion identifier |
| promotion_name | string | Promotion name |
| redemption_month | string | Month in format "YYYY-MM" (from ordered_at) |
| monthly_redemptions | integer | Redemptions in this month |
| monthly_discount | decimal(2) | Discount given in this month |
| monthly_order_value | decimal(2) | Order value in this month |
| monthly_unique_customers | integer | Unique customers in month |
| monthly_first_time_count | integer | First-time buyer redemptions |
| cumulative_redemptions | integer | Running total of redemptions |
| cumulative_discount | decimal(2) | Running total of discount |
| cumulative_order_value | decimal(2) | Running total of order value |
| month_rank | integer | Rank of this month for this promotion (1 = first) |
| pct_of_total_redemptions | decimal(1) | This month's % of promotion total |
| monthly_revenue_per_discount | decimal(2) | Monthly revenue per $1 discount |
| weekday_redemptions | integer | Mon-Fri redemptions this month |
| weekend_redemptions | integer | Sat-Sun redemptions this month |
| weekday_order_value | decimal(2) | Order value from weekday redemptions |
| weekend_order_value | decimal(2) | Order value from weekend redemptions |
| weekday_avg_order_value | decimal(2) | Avg order value on weekdays (NULL if 0 weekday redemptions) |
| weekend_avg_order_value | decimal(2) | Avg order value on weekends (NULL if 0 weekend redemptions) |
| weekend_lift_pct | decimal(1) | ((weekend_avg - weekday_avg) / weekday_avg) x 100 (NULL if either is NULL or weekday_avg is 0) |

Order by promotion_id, redemption_month.

## Materialization

- Intermediate models: views
- `coupon_effectiveness`: table
- `coupon_summary`: table
- `coupon_trends`: table

## Verification

```bash
cd /app/dbt_transforms  # or /app/dbt_models_snowflake for Snowflake
dbt run --select +coupon_effectiveness +coupon_summary +coupon_trends
```

## Guidelines

- Use conditional logic for database-specific syntax where necessary
