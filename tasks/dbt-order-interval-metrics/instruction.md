# Customer Order Interval Analysis

Build dbt models that analyze the time intervals between consecutive customer orders to understand purchasing patterns, classify customers by their ordering frequency, assess customer value and churn risk, track behavioral momentum, and predict customer lifecycle stages.

## Database Backend

This task supports both DuckDB and Snowflake. **Run `echo $DB_TYPE` in a shell BEFORE you write any code or spawn any subagents — the live env determines which backend the verifier runs against.** Do NOT assume a default from this prose. Both `/app/dbt_models_duckdb/` and `/app/dbt_models_snowflake/` exist on disk; the verifier only checks the project matching the live `$DB_TYPE`.

### DuckDB
- Set `DB_TYPE=duckdb`
- Database path: `$DUCKDB_PATH` (default: `/app/database/retail.duckdb`)
- dbt project: `/app/dbt_models_duckdb`

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
- dbt project: `/app/dbt_models_snowflake`

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

## Project Setup
You will add models to the existing dbt project. The project is already configured with:
- Source definitions for `enterprise_db` schema

**Important**:
- Run `dbt deps` before `dbt run` to install dependencies
- Use `{{ source('enterprise_db', 'TABLE_NAME') }}` syntax to reference source tables
- Analysis period: Full year 2024 (January 1, 2024 to December 31, 2024)
- Reference date: December 31, 2024 (for calculating days since last order)
- Target schema: `order_analytics` (will appear as `main_order_analytics` in DuckDB, or default schema in Snowflake)

**Snowflake schema routing**: On Snowflake, models must land in the `main` schema (the default schema of the clone database). To achieve this, override the `generate_schema_name` macro so that dbt places all models in the target schema defined in `profiles.yml`, ignoring any custom schema config. Create `macros/generate_schema_name.sql` (or overwrite the existing one if present) with a macro that returns the default schema unconditionally. Set the Snowflake profile's schema to `main`.

## Source Data

Reference source tables using `{{ source('enterprise_db', 'TABLE_NAME') }}` syntax.

### orders table (`{{ source('enterprise_db', 'ORDERS') }}`)
Contains order data including order_id, customer_id, ordered_at, grand_total, and status columns. Explore the table to understand available columns and data types.

## Required Models

### 1. Staging Model (`models/staging/stg_orders__timeline.sql`)
- Filter orders to year 2024: `ordered_at >= '2024-01-01'` AND `ordered_at < '2025-01-01'`
- Exclude cancelled, returned, and failed orders: trim whitespace from status before checking against 'CANCELLED', 'RETURNED', 'FAILED'
- Include columns: order_id, customer_id, order_date (as DATE, not TIMESTAMP), grand_total
- Trim whitespace from string columns

### 2. Intermediate Model (`models/intermediate/int_customer_order_gaps.sql`)
Calculate the time gap between consecutive orders for each customer:

| Column | Type | Description |
|--------|------|-------------|
| customer_id | VARCHAR | Customer identifier |
| order_date | DATE | Date of the order |
| grand_total | DECIMAL | Order amount |
| order_sequence | INTEGER | Sequential order number for this customer (1, 2, 3...) |
| prev_order_date | DATE | Date of customer's previous order (NULL for first order) |
| days_since_prev_order | INTEGER | Days between this order and previous order (NULL for first order) |
| order_half | VARCHAR | 'first_half' or 'second_half' - which half of customer's orders this belongs to |

**Important**: Order sequence must be based on order_date ascending for each customer. For tie-breaking, use order_id ascending.

### 3. Mart Model (`models/marts/customer_order_intervals.sql`)
Create a **table** with one row per customer containing interval metrics, with these columns in exact order:

| Column | Type | Description |
|--------|------|-------------|
| customer_id | VARCHAR | Customer identifier |
| total_orders | INTEGER | Total number of orders by this customer |
| first_order_date | DATE | Date of customer's first order |
| last_order_date | DATE | Date of customer's most recent order |
| customer_lifespan_days | INTEGER | Days between first and last order (0 if only 1 order) |
| total_revenue | DECIMAL(12,2) | Sum of all order amounts |
| avg_order_value | DECIMAL(12,2) | total_revenue / total_orders |
| avg_days_between_orders | DECIMAL(8,2) | Average days between consecutive orders (NULL if only 1 order) |
| min_days_between_orders | INTEGER | Minimum gap between orders (NULL if only 1 order) |
| max_days_between_orders | INTEGER | Maximum gap between orders (NULL if only 1 order) |
| std_dev_days | DECIMAL(8,2) | Standard deviation of order intervals (NULL if fewer than 3 orders) |
| ordering_frequency | VARCHAR | Frequency classification (see rules below) |
| is_repeat_customer | VARCHAR(1) | 'Y' if total_orders > 1, 'N' otherwise |
| days_since_last_order | INTEGER | Days from last_order_date to reference date (2024-12-31) |
| customer_tier | VARCHAR | Value tier based on revenue quartiles (see rules below) |
| churn_risk | VARCHAR | Churn risk assessment (see rules below) |
| purchase_consistency | VARCHAR | Ordering pattern consistency (see rules below) |
| customer_value_score | INTEGER | Composite value score 0-100 (see calculation below) |
| customer_segment | VARCHAR | Customer segment based on value score (see rules below) |
| order_acceleration | VARCHAR | Whether ordering frequency is accelerating or decelerating (see rules below) |
| monthly_order_rate | DECIMAL(8,2) | Orders per month of active period (see calculation below) |
| spending_trend | VARCHAR | Whether spending per order is trending up or down (see rules below) |
| loyalty_index | INTEGER | Composite loyalty score 0-100 (see calculation below) |
| engagement_momentum | VARCHAR | Behavioral trajectory classification (see rules below) |
| lifecycle_stage | VARCHAR | Customer lifecycle stage classification (see rules below) |

### Ordering Frequency Classification Rules
Based on avg_days_between_orders:
- 'One-time' when total_orders = 1
- 'Frequent' when avg_days_between_orders < 30
- 'Regular' when avg_days_between_orders >= 30 AND < 90
- 'Occasional' when avg_days_between_orders >= 90 AND < 180
- 'Rare' when avg_days_between_orders >= 180

### Customer Tier Classification Rules
Divide customers into four equal-sized groups (quartiles) by total_revenue:
- 'Platinum' for customers in the top 25% by revenue
- 'Gold' for customers in the 50th-75th percentile
- 'Silver' for customers in the 25th-50th percentile
- 'Bronze' for customers in the bottom 25%

### Churn Risk Classification Rules
Based on days_since_last_order and total_orders:
- 'High' when days_since_last_order >= 120
- 'High' when days_since_last_order >= 60 AND total_orders = 1 (one-time buyer who hasn't returned)
- 'Medium' when days_since_last_order >= 60 AND total_orders > 1
- 'Low' when days_since_last_order < 60

**Important**: Evaluate the conditions in order - a customer with days_since >= 120 should be 'High' regardless of total_orders.

### Purchase Consistency Classification Rules
Based on coefficient of variation (CV) of order intervals (std_dev / mean):
- 'High' when CV < 0.5 (consistent ordering pattern)
- 'Medium' when CV >= 0.5 AND CV < 1.0
- 'Low' when CV >= 1.0 (irregular ordering pattern)
- NULL when std_dev_days is NULL (fewer than 3 orders)

### Customer Value Score Calculation (0-100)
A composite RFM-style score combining three components:

1. **Revenue Component (0-40 points)**: Based on customer's percentile position in revenue distribution
   - Customer at the top of revenue distribution gets 40 points
   - Customer at the bottom gets 0 points
   - Scale linearly between these extremes, rounded to nearest integer

2. **Frequency Component (0-30 points)**: Based on ordering_frequency classification
   - 'Frequent' = 30 points
   - 'Regular' = 20 points
   - 'Occasional' = 10 points
   - 'Rare' or 'One-time' = 5 points

3. **Recency Component (0-30 points)**: Linear decay over one year
   - Customer who ordered today (0 days ago) gets 30 points
   - Customer who ordered 365+ days ago gets 0 points
   - Decay linearly between these extremes, rounded to nearest integer

**Final Score**: Sum of all three components as an integer (minimum 5, maximum 100)

### Customer Segment Classification Rules
Based on customer_value_score:
- 'Champion' when score >= 80
- 'Loyal' when score >= 60 AND score < 80
- 'Potential' when score >= 40 AND score < 60
- 'At Risk' when score >= 20 AND score < 40
- 'Hibernating' when score < 20

### Order Acceleration Classification Rules
Compare average days between orders in the first half of a customer's orders to the second half:
- 'Accelerating' when second_half_avg_gap < first_half_avg_gap * 0.8 (ordering more frequently)
- 'Decelerating' when second_half_avg_gap > first_half_avg_gap * 1.2 (ordering less frequently)
- 'Stable' when the ratio is between 0.8 and 1.2
- NULL when total_orders < 4 (not enough orders to compare halves)

**Note**: For customers with odd number of orders, the middle order goes to the first half.

### Monthly Order Rate Calculation
Calculate orders per month based on active period:
- monthly_order_rate = total_orders / GREATEST(1, customer_lifespan_days / 30.0)
- Round to 2 decimal places
- For single-order customers, this equals total_orders (1.00)

### Spending Trend Classification Rules
Compare average order value in the first half of orders to the second half:
- 'Increasing' when second_half_avg_value > first_half_avg_value * 1.1
- 'Decreasing' when second_half_avg_value < first_half_avg_value * 0.9
- 'Stable' when the ratio is between 0.9 and 1.1
- NULL when total_orders = 1 (single order, no trend possible)

### Loyalty Index Calculation (0-100)
A composite score measuring customer loyalty:

1. **Tenure Component (0-30 points)**: Based on customer_lifespan_days
   - 300+ days = 30 points
   - 200-299 days = 24 points
   - 100-199 days = 18 points
   - 50-99 days = 12 points
   - 1-49 days = 6 points
   - 0 days (single order) = 0 points

2. **Repeat Purchase Component (0-40 points)**: Based on total_orders
   - 20+ orders = 40 points
   - 10-19 orders = 32 points
   - 5-9 orders = 24 points
   - 3-4 orders = 16 points
   - 2 orders = 8 points
   - 1 order = 0 points

3. **Consistency Component (0-30 points)**: Based on purchase_consistency
   - 'High' = 30 points
   - 'Medium' = 20 points
   - 'Low' = 10 points
   - NULL = 5 points (benefit of doubt for new customers)

**Final Score**: Sum of all three components as an integer (minimum 0, maximum 100)

### Engagement Momentum Classification Rules
Combine order_acceleration and spending_trend to determine behavioral trajectory:
- 'Accelerating' when order_acceleration = 'Accelerating' AND spending_trend IN ('Increasing', 'Stable')
- 'Stable' when order_acceleration = 'Stable' AND spending_trend = 'Stable'
- 'Decelerating' when order_acceleration = 'Decelerating' OR spending_trend = 'Decreasing'
- 'Emerging' when total_orders < 4 AND days_since_last_order < 60 (new customers with recent activity)
- 'Inactive' when days_since_last_order >= 90 (regardless of other factors)

**Note**: Evaluate 'Inactive' first (highest priority), then 'Emerging', then the acceleration/deceleration logic.

### Lifecycle Stage Classification Rules
Based on combination of total_orders, days_since_last_order, and customer_lifespan_days. Evaluate conditions in this order (first match wins):
- 'Churned' when days_since_last_order >= 120
- 'Declining' when customer_lifespan_days >= 90 AND days_since_last_order >= 60 AND days_since_last_order < 120
- 'New' when total_orders <= 2 AND customer_lifespan_days < 60
- 'Growing' when total_orders >= 3 AND customer_lifespan_days < 180 AND days_since_last_order < 60
- 'Mature' when customer_lifespan_days >= 180 AND days_since_last_order < 90

**Important**: 'Churned' takes highest priority -- a customer with days_since_last_order >= 120 is always 'Churned' regardless of other conditions.

## Output Requirements

1. **Model Names**: All three models must exist with exact names specified
2. **Materialization**: The mart model must be materialized as TABLE (not view)
3. **Column Order**: Columns must appear in the exact order specified (25 columns total)
4. **Data Types**:
   - Dates must be DATE type (not TIMESTAMP)
   - Monetary values rounded to 2 decimal places
   - avg_days_between_orders rounded to 2 decimal places
   - std_dev_days rounded to 2 decimal places
   - monthly_order_rate rounded to 2 decimal places
   - ordering_frequency must be exactly 'One-time', 'Frequent', 'Regular', 'Occasional', or 'Rare'
   - is_repeat_customer must be exactly 'Y' or 'N'
   - customer_tier must be exactly 'Platinum', 'Gold', 'Silver', or 'Bronze'
   - churn_risk must be exactly 'High', 'Medium', or 'Low'
   - purchase_consistency must be exactly 'High', 'Medium', 'Low', or NULL
   - customer_value_score must be an INTEGER between 0 and 100
   - customer_segment must be exactly 'Champion', 'Loyal', 'Potential', 'At Risk', or 'Hibernating'
   - order_acceleration must be exactly 'Accelerating', 'Stable', 'Decelerating', or NULL
   - spending_trend must be exactly 'Increasing', 'Stable', 'Decreasing', or NULL
   - loyalty_index must be an INTEGER between 0 and 100
   - engagement_momentum must be exactly 'Accelerating', 'Stable', 'Decelerating', 'Emerging', or 'Inactive'
   - lifecycle_stage must be exactly 'New', 'Growing', 'Mature', 'Declining', or 'Churned'
5. **NULL Handling**:
   - Single-order customers: NULL for avg_days_between_orders, min_days_between_orders, max_days_between_orders, spending_trend
   - Customers with fewer than 3 orders: NULL for std_dev_days and purchase_consistency
   - Customers with fewer than 4 orders: NULL for order_acceleration
6. **Ordering**: Results ordered by total_revenue descending (highest value customers first)
7. **Idempotency**: Multiple dbt runs must produce identical results

## Guidelines

- The SQL syntax should work on both DuckDB and Snowflake (ANSI SQL compatible)
- Reference date for days_since_last_order calculation is '2024-12-31'
- Ensure deterministic results across multiple runs
- Use sample standard deviation (not population) for std_dev_days calculation
- For half-based calculations, split orders by sequence number: first_half includes sequences 1 to CEIL(total_orders/2), second_half includes the rest
