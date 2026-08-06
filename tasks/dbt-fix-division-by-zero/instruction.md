# Fix and Enhance Customer Metrics Model

## Objective

Fix a dbt model with data quality issues in customer metrics and add new analytical columns.

## Background

The `rpt_customer_metrics` model has bugs causing invalid values (infinity, NaN). Additionally, we need new metrics for customer segmentation, churn prediction, and peer comparison.

## Your Task

Fix the `rpt_customer_metrics.sql` model to produce correct output with all required new columns.

- DuckDB: `/app/dbt_models_duckdb/models/marts/customer/rpt_customer_metrics.sql`
- Snowflake: `/app/dbt_models_snowflake/models/marts/customer/rpt_customer_metrics.sql`

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

The model uses the staging table:
- **int_sales__orders_enriched** - Contains order-level data with customer_id, grand_total, ordered_at, and status columns. Explore to understand available columns.

## Current Issues

The existing model has problems that need to be resolved:

1. Division by zero errors producing `inf` and `nan` values in calculated columns
2. NULL customer_id records not excluded from the source query
3. Incorrect filtering (WHERE total_revenue > 0) excludes valid customers
4. Missing columns required for customer segmentation and analytics

## Tasks

### 1. Fix Existing Bugs

The model produces `inf` and `nan` values. Fix all division-by-zero issues using NULLIF or similar patterns.

Also exclude records where `customer_id` is NULL from the source query.

### 2. Add Customer Engagement Score

Add a new column `customer_engagement_score` (0-100) that combines multiple factors:

| Factor    | Weight | Calculation                                               |
| --------- | ------ | --------------------------------------------------------- |
| Recency   | 30%    | `min(1.0, max(0, (365 - days_since_last_order) / 365))` |
| Frequency | 35%    | `min(1.0, max(0, orders_per_month / 5.0))`              |
| Monetary  | 35%    | Use PERCENT_RANK() on total_revenue                       |

Formula: `(recency_factor * 0.30 + frequency_factor * 0.35 + monetary_factor * 0.35) * 100`

Ensure the score is bounded between 0 and 100. For engagement score inputs, treat NULL values as 0, **except `days_since_last_order`** where NULL means no recent order — treat as 365 days (so recency factor = 0). Use `COALESCE(days_since_last_order, 365)` in the recency calculation.

### 3. Add Customer Lifetime Value Tier

Add a new column `ltv_tier` that categorizes customers using waterfall logic (check in order):

| Tier     | Criteria                                                                  |
| -------- | ------------------------------------------------------------------------- |
| vip      | revenue_percentile >= 0.95 AND orders_last_90d > 0 AND total_orders >= 10 |
| platinum | revenue_percentile >= 0.90 AND orders_last_180d > 0                       |
| gold     | revenue_percentile >= 0.75 OR avg_order_value > 500                       |
| silver   | total_orders >= 3 AND total_revenue > 100                                 |
| bronze   | total_orders >= 1 AND total_revenue > 50                                  |
| at_risk  | total_orders > 0 AND days_since_last_order > 365                          |
| inactive | All others                                                                |

Use `revenue_percentile` calculated with PERCENT_RANK() on total_revenue. Treat NULL percentiles as 0.

### 4. Add Churn Risk Score

Add a new column `churn_risk_score` (0-100) that predicts customer churn:

| Factor            | Weight | Calculation                                        |
| ----------------- | ------ | -------------------------------------------------- |
| Days inactive     | 40%    | `min(1.0, max(0, COALESCE(days_since_last_order, 365) / 365))`  |
| Declining orders  | 30%    | `1.0 - min(1.0, max(0, order_frequency_trend))`                 |
| Declining revenue | 30%    | `1.0 - min(1.0, max(0, revenue_velocity_ratio))`                |

Formula: `(inactive_factor * 0.40 + declining_orders_factor * 0.30 + declining_revenue_factor * 0.30) * 100`

Higher score = higher churn risk. Bound between 0-100. Note: NULL handling for churn risk differs from engagement score — customers with unknown `days_since_last_order` should be treated as maximally inactive: use `COALESCE(days_since_last_order, 365)` so NULL yields inactive_factor = 1.0 (not 0).

### 5. Add Customer Peer Comparison Metrics

Add columns that compare each customer to their peers:

| Column                    | Description                                                        |
| ------------------------- | ------------------------------------------------------------------ |
| customer_value_rank       | Rank by total_revenue (highest = 1) using DENSE_RANK               |
| customer_value_percentile | PERCENT_RANK by total_revenue (higher revenue = higher percentile) |
| above_median_revenue      | 1 if total_revenue > median, else 0                                |

## Expected Output

| Column                    | Type    | Description                                                  |
| ------------------------- | ------- | ------------------------------------------------------------ |
| customer_id               | varchar | Unique customer identifier                                   |
| total_orders              | integer | Total number of orders placed by the customer                |
| total_revenue             | decimal | Total revenue generated by the customer                      |
| first_order_date          | date    | Date of the customer's first order                           |
| last_order_date           | date    | Date of the customer's most recent order                     |
| days_since_last_order     | integer | Days since most recent order (relative to the most recent order date in the data) |
| orders_last_30d           | integer | Number of orders in the last 30 days (relative to the most recent order date in the data) |
| orders_last_90d           | integer | Number of orders in the last 90 days (relative to the most recent order date in the data) |
| orders_last_180d          | integer | Number of orders in the last 180 days (relative to the most recent order date in the data) |
| revenue_last_30d          | decimal | Revenue generated in the last 30 days (relative to the most recent order date in the data) |
| revenue_last_90d          | decimal | Revenue generated in the last 90 days (relative to the most recent order date in the data) |
| avg_order_value           | decimal | Average revenue per order                                    |
| orders_per_month          | decimal | Average number of orders per month (relative to the most recent order date in the data) |
| revenue_velocity_ratio    | decimal | Recent revenue vs historical revenue ratio                   |
| order_frequency_trend     | decimal | Trend metric indicating increase/decrease in order frequency |
| customer_engagement_score | decimal | Customer engagement composite score (0-100)                  |
| churn_risk_score          | decimal | Churn risk prediction score (0-100)                          |
| customer_value_rank       | integer | Rank by total revenue (1 = highest)                          |
| customer_value_percentile | decimal | Percentile by total revenue                                  |
| above_median_revenue      | integer | 1 if above median revenue, 0 otherwise                       |
| ltv_tier                  | varchar | Customer lifetime value tier classification                  |

## Success Criteria

1. Model compiles and runs without errors
2. No infinity or NaN values in any numeric columns
3. Row count matches the number of distinct non-NULL customers in the source
4. All new columns exist with correct calculations
5. Engagement and churn scores bounded 0-100
6. LTV tier waterfall logic produces valid tier names with reasonable distribution

## Guidelines

- Use Jinja conditionals (`{% if target.type == 'duckdb' %}...{% else %}...{% endif %}`) for syntax that differs between backends
- Key differences: DuckDB uses `date_diff()` and `INTERVAL '30' day`; Snowflake uses `DATEDIFF()` and `DATEADD()`
- `PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY col) OVER ()` works in DuckDB but NOT in Snowflake; use a subquery or `MEDIAN()` for Snowflake
- Use `MAX(ordered_at)` from the source data as the reference date for all time-based calculations (do NOT use `CURRENT_DATE` — the data may not extend to the present day)
