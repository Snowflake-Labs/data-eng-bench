# Customer Lifetime Value (CLV) Analysis

Build an advanced Customer Lifetime Value analytics suite for our retail data warehouse. This includes CLV predictions with NPV discounting, customer health scoring, lifecycle classification, value trajectory analysis, churn probability modeling, and cohort-based retention analysis.

## Database Backend

This task supports two database backends:

- **DuckDB**: Local DuckDB database at `/app/database/retail.duckdb`. The dbt project is at `/app/dbt_models_duckdb/`.
- **Snowflake**: Cloud Snowflake database. Connection details are provided via environment variables (`SNOWFLAKE_ACCOUNT`, `SNOWFLAKE_USER`, `SNOWFLAKE_PASSWORD`, `SNOWFLAKE_DATABASE`, `SNOWFLAKE_SCHEMA`, `SNOWFLAKE_WAREHOUSE`, `SNOWFLAKE_ROLE`). The dbt project is at `/app/dbt_models_snowflake/`.

Check the `DB_TYPE` environment variable to determine which backend is active.

## dbt Profile Setup

Create a `profiles.yml` in the appropriate dbt project directory with profile name `retail_dw_master`:

- For DuckDB: Configure with `type: duckdb` and `path` pointing to the database file.
- For Snowflake: Configure with `type: snowflake` and use the environment variables for connection settings (password authentication). Set the profile's `schema:` to `$SNOWFLAKE_SCHEMA` — do NOT leave it blank (a blank schema makes Snowflake default to `PUBLIC`, so models land in the wrong schema and the verifier cannot find them).

## Environment

- **dbt project (DuckDB)**: `/app/dbt_models_duckdb`
- **dbt project (Snowflake)**: `/app/dbt_models_snowflake`
- **Analysis date**: December 1, 2024
- **Analysis period**: January 1, 2023 through November 30, 2024

## Source Data

The staging layer provides:

- `stg_orders__orders`: order_id, customer_id, ordered_at, grand_total, status, test_order_flag
- `stg_customer__customers`: customer_id, first_name, last_name, status

## Requirements

### Data Rules

Only include orders that are:
- Status is not CANCELLED, RETURNED, or FAILED
- Not a test order (test_order_flag is not 1 or true)
- Within the analysis period

Only include customers with at least 2 qualifying orders (CLV requires purchase frequency data).

### Models to Create

Create these dbt models:

1. **Intermediate models** in `models/intermediate/`:
   - `int_clv_customer_orders`: Per-order data with `days_since_previous_order` using LAG. Include `ordered_at` timestamp and `grand_total`.
   - `int_clv_metrics`: Customer-level aggregated metrics.

2. **Mart models** in `models/marts/customer/`:
   - `clv_predictions`: CLV projections and health indicators
   - `clv_segments`: Final customer-level output (table)
   - `clv_segment_summary`: Segment-level aggregates (table)
   - `clv_cohort_analysis`: Quarterly cohort retention analysis (table)
   - `clv_monthly_trends`: Monthly revenue trends by customer (table)

### CLV Calculations

**Basic Metrics:**
- **orders_per_year**: 365 / avg_days_between_orders (0 if division error)
- **predicted_annual_revenue**: orders_per_year * avg_order_value
- **clv_3_year**: predicted_annual_revenue * 3

**Discounted CLV (Net Present Value):**

Calculate the NPV of projected 3-year revenue using an 8% annual discount rate:
- **clv_3_year_npv**: Year 1 revenue + (Year 2 revenue / 1.08) + (Year 3 revenue / 1.08^2)

Where each year's revenue = predicted_annual_revenue. The formula simplifies to:
```
clv_3_year_npv = predicted_annual_revenue * (1 + 1/1.08 + 1/1.1664)
```

Round the multiplier to 4 decimal places first (2.7833), then multiply by predicted_annual_revenue and round to 2 decimal places.

**Rounding Rules:**
- Round monetary values to 2 decimal places
- Round avg_days_between_orders to 1 decimal place
- Round orders_per_year to 2 decimal places
- Round percentages to 1 decimal place
- Round scores to 1 decimal place

**Important**: Use rounded values from previous calculations in subsequent calculations.

### Customer Health Metrics

- **days_since_last_order**: Days from last_order_date to 2024-12-01
- **is_at_risk**: True if days_since_last_order > 2 * avg_days_between_orders
- **clv_percentile**: PERCENT_RANK by clv_3_year within segment (0-100, 1 decimal)
- **clv_quartile**: NTILE(4) by clv_3_year within segment (1=lowest, 4=highest)

### Value Trajectory Analysis

Compare customer's order values over time to determine their value trajectory.

Calculate:
- **first_half_avg**: Average order value of the customer's first half of orders (if odd number, include middle order in first half)
- **second_half_avg**: Average order value of the customer's second half of orders (if odd number, exclude middle order from second half)

For a customer with 5 orders: first half = orders 1,2,3; second half = orders 4,5.

**value_trajectory**:
- `Accelerating`: second_half_avg > first_half_avg * 1.1 (more than 10% increase)
- `Decelerating`: second_half_avg < first_half_avg * 0.9 (more than 10% decrease)
- `Stable`: otherwise

For customers with exactly 2 orders: compare second order to first order using same thresholds.

### Order Velocity Trend

Compare recent ordering frequency to historical patterns.

For customers with 4+ orders:
- **recent_avg_days**: Average of the 2 most recent inter-order gaps (gaps between orders N-2->N-1 and N-1->N)
- **historical_avg_days**: Average of all inter-order gaps except the 2 most recent

Example: A customer with 5 orders has 4 gaps. recent_avg_days uses gaps 3 and 4; historical_avg_days uses gaps 1 and 2.

**velocity_trend**:
- `Accelerating`: recent_avg_days < historical_avg_days * 0.8 (ordering 20% faster)
- `Slowing`: recent_avg_days > historical_avg_days * 1.2 (ordering 20% slower)
- `Stable`: otherwise

For customers with 2-3 orders, set velocity_trend to `Insufficient Data`.

### Churn Probability Score

Calculate a churn probability score from 0 to 100 based on multiple factors:

**Score Components:**
1. **Recency Score** (0-40 points):
   - 0 points if days_since_last_order <= avg_days_between_orders
   - Linear increase: min(40, (days_since_last_order - avg_days_between_orders) / avg_days_between_orders * 20)

2. **Frequency Score** (0-30 points):
   - 30 points if orders_per_year < 1
   - 20 points if orders_per_year >= 1 and < 2
   - 10 points if orders_per_year >= 2 and < 4
   - 0 points if orders_per_year >= 4

3. **Trend Score** (0-30 points):
   - 30 points if velocity_trend = 'Slowing'
   - 15 points if velocity_trend = 'Stable' or 'Insufficient Data'
   - 0 points if velocity_trend = 'Accelerating'

**churn_probability_score**: Sum of all component scores, capped at 100. Round to 1 decimal place.

### Revenue Concentration

Calculate each customer's contribution to total revenue:

- **revenue_contribution_pct**: customer's total_revenue / sum of all customers' total_revenue * 100 (1 decimal)
- **cumulative_revenue_pct**: Running sum of revenue_contribution_pct when customers are ordered by total_revenue DESC (1 decimal)
- **revenue_rank**: Dense rank by total_revenue DESC (1 = highest revenue customer)

### Customer Engagement Score

Calculate a composite engagement score from 0 to 100:

**Components (weighted):**
1. **Recency Component** (30% weight):
   - Score = max(0, 100 - (days_since_last_order / 3.65))
   - Caps at 0 for customers inactive 365+ days

2. **Frequency Component** (30% weight):
   - Score = min(100, orders_per_year * 20)
   - 5+ orders/year = 100 points

3. **Monetary Component** (25% weight):
   - Score = min(100, clv_percentile)
   - Uses the clv_percentile within segment

4. **Consistency Component** (15% weight):
   - If customer has 3+ orders: Score = max(0, 100 - coefficient_of_variation * 100)
   - coefficient_of_variation = stddev(days_between_orders) / avg(days_between_orders)
   - If customer has 2 orders: Score = 50

**engagement_score**: Weighted sum of components. Round to 1 decimal place.

### Expected Next Order

- **expected_next_order_date**: last_order_date + avg_days_between_orders (rounded to nearest day)
- **days_until_expected_order**: expected_next_order_date - 2024-12-01 (can be negative if overdue)
- **days_overdue**: max(0, -days_until_expected_order) -- how many days past the expected date

### Customer Lifecycle Stage

Assign a lifecycle stage based on purchase patterns:

| Stage | Criteria |
|-------|----------|
| New | total_orders = 2 AND customer_tenure_days <= 90 |
| Growing | total_orders >= 3 AND orders_per_year > 4 AND NOT is_at_risk AND value_trajectory != 'Decelerating' |
| Mature | total_orders >= 3 AND orders_per_year <= 4 AND NOT is_at_risk AND value_trajectory != 'Decelerating' |
| Declining | is_at_risk = true AND days_since_last_order <= 365 |
| Churned | days_since_last_order > 365 |
| At Risk - High Value | is_at_risk = true AND days_since_last_order <= 365 AND clv_segment IN ('Platinum', 'Gold') |

Evaluate conditions in the order shown (first matching condition wins). Note: "At Risk - High Value" should be checked BEFORE "Declining".

### Segments

| Segment | clv_3_year threshold |
|---------|---------------------|
| Platinum | >= 5000 |
| Gold | >= 2000 and < 5000 |
| Silver | >= 500 and < 2000 |
| Bronze | < 500 |

## Output: clv_segments

| Column | Type | Description |
|--------|------|-------------|
| customer_id | string | Customer identifier |
| customer_name | string | "first_name last_name" or "Customer {id}" if empty |
| first_order_date | timestamp | First qualifying order |
| last_order_date | timestamp | Most recent qualifying order |
| customer_tenure_days | integer | Days from first order to 2024-12-01 |
| days_since_last_order | integer | Days from last order to 2024-12-01 |
| total_orders | integer | Count of qualifying orders |
| total_revenue | decimal(2) | Sum of grand_total |
| avg_order_value | decimal(2) | total_revenue / total_orders |
| avg_days_between_orders | decimal(1) | Mean days between orders |
| orders_per_year | decimal(2) | Annualized frequency |
| predicted_annual_revenue | decimal(2) | Projected yearly spend |
| clv_3_year | decimal(2) | 3-year projected value |
| clv_3_year_npv | decimal(2) | 3-year NPV at 8% discount rate |
| clv_segment | string | Platinum/Gold/Silver/Bronze |
| is_at_risk | boolean | Overdue for purchase |
| clv_percentile | decimal(1) | Percentile within segment (0-100) |
| clv_quartile | integer | Quartile within segment (1-4) |
| lifecycle_stage | string | New/Growing/Mature/Declining/Churned/At Risk - High Value |
| first_order_quarter | string | Quarter of first order (e.g., "2023-Q1") |
| value_trajectory | string | Accelerating/Stable/Decelerating |
| velocity_trend | string | Accelerating/Stable/Slowing/Insufficient Data |
| churn_probability_score | decimal(1) | Churn risk score 0-100 |
| revenue_contribution_pct | decimal(1) | Percent of total revenue |
| cumulative_revenue_pct | decimal(1) | Cumulative revenue percent (by revenue rank) |
| revenue_rank | integer | Rank by total revenue (1=highest) |
| engagement_score | decimal(1) | Composite engagement 0-100 |
| expected_next_order_date | date | Predicted next order date |
| days_until_expected_order | integer | Days until expected order (negative if overdue) |
| days_overdue | integer | Days past expected order date (0 if not overdue) |

No NULL values (use appropriate defaults). One row per customer. Order by customer_id.

## Output: clv_segment_summary

| Column | Type | Description |
|--------|------|-------------|
| clv_segment | string | Segment name |
| customer_count | integer | Customers in segment |
| total_revenue | decimal(2) | Sum of revenue |
| avg_clv_3_year | decimal(2) | Average 3-year CLV |
| avg_clv_3_year_npv | decimal(2) | Average 3-year NPV |
| avg_orders_per_year | decimal(2) | Average frequency |
| at_risk_count | integer | At-risk customers |
| at_risk_percentage | decimal(1) | Percent at risk |
| churned_count | integer | Churned customers |
| avg_tenure_days | decimal(1) | Average customer tenure |
| avg_engagement_score | decimal(1) | Average engagement score |
| avg_churn_probability | decimal(1) | Average churn probability score |
| accelerating_count | integer | Customers with value_trajectory = 'Accelerating' |
| decelerating_count | integer | Customers with value_trajectory = 'Decelerating' |
| pct_revenue_contribution | decimal(1) | Segment's percent of total revenue |

Order by avg_clv_3_year DESC.

## Output: clv_cohort_analysis

Cohort analysis by first purchase quarter. Each row represents one cohort.

| Column | Type | Description |
|--------|------|-------------|
| cohort_quarter | string | Quarter of first purchase (e.g., "2023-Q1") |
| cohort_size | integer | Customers who made first purchase in this quarter |
| total_cohort_revenue | decimal(2) | Total revenue from cohort |
| avg_clv_3_year | decimal(2) | Average CLV for cohort |
| avg_clv_3_year_npv | decimal(2) | Average NPV for cohort |
| avg_orders | decimal(2) | Average orders per customer |
| retention_rate | decimal(1) | Percent still active (NOT churned) |
| at_risk_rate | decimal(1) | Percent at risk |
| avg_engagement_score | decimal(1) | Average engagement score |
| avg_churn_probability | decimal(1) | Average churn probability |
| platinum_count | integer | Count in Platinum segment |
| gold_count | integer | Count in Gold segment |
| silver_count | integer | Count in Silver segment |
| bronze_count | integer | Count in Bronze segment |
| accelerating_pct | decimal(1) | Percent with accelerating value trajectory |
| decelerating_pct | decimal(1) | Percent with decelerating value trajectory |

Order by cohort_quarter ASC.

## Output: clv_monthly_trends

Monthly aggregated metrics per customer. One row per customer per month they had orders.

| Column | Type | Description |
|--------|------|-------------|
| customer_id | string | Customer identifier |
| order_month | string | Month in format "YYYY-MM" |
| monthly_orders | integer | Orders placed in this month |
| monthly_revenue | decimal(2) | Revenue from this month |
| cumulative_orders | integer | Running total of orders up to and including this month |
| cumulative_revenue | decimal(2) | Running total of revenue up to and including this month |
| months_since_first_order | integer | Number of months since customer's first order (0 for first month) |
| avg_monthly_revenue | decimal(2) | cumulative_revenue / (months_since_first_order + 1) |
| is_active_month | boolean | True if customer placed at least one order this month |
| order_month_rank | integer | Rank of this month within customer's order history (1 = first month with orders) |

Order by customer_id, order_month.

Note: Only include months where the customer actually placed orders. The months_since_first_order should be calculated as the difference in months between this order_month and the customer's first order month.

## Materialization

- Intermediate models: views
- `clv_predictions`: view
- `clv_segments`: table
- `clv_segment_summary`: table
- `clv_cohort_analysis`: table
- `clv_monthly_trends`: table

## SQL Compatibility Guidelines

When writing SQL models that need to work on both DuckDB and Snowflake, use Jinja conditionals:
- `strftime(date, format)` (DuckDB) vs `TO_CHAR(date, format)` (Snowflake)
- `date_diff('day', a, b)` or `datediff('day', a, b)` (DuckDB) vs `DATEDIFF('day', a, b)` (Snowflake)
- `interval '1 day' * N` (DuckDB) vs `DATEADD('day', N, date)` (Snowflake)
- `a // b` integer division (DuckDB) vs `FLOOR(a / b)` (Snowflake)
- Use `{% if target.type == 'snowflake' %}` for database-specific syntax

## Verification

```bash
cd $DBT_PROJECT_DIR
dbt run --select +clv_segments +clv_segment_summary +clv_cohort_analysis +clv_monthly_trends
```
