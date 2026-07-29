# Product Sales Velocity Analysis

Build dbt models that analyze product sales velocity, monthly demand shifts, and category-relative performance to create a product velocity scorecard with composite scoring and multi-factor classification.

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

## Data Environment
- **dbt project**:
  - DuckDB: `/app/dbt_models_duckdb` (existing project - add your models here)
  - Snowflake: `/app/dbt_models_snowflake` (existing project - add your models here)
- **Analysis period**: Full year 2024 (January 1, 2024 to December 31, 2024)
- **Target schema**: `velocity_analytics` (will appear as `main_velocity_analytics` in database)

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
You will add models to the existing dbt project.

**Important**:
- Run `dbt deps` before `dbt run` to install dependencies
- Use `{{ source('enterprise_db', 'TABLE_NAME') }}` syntax to reference source tables
- The mart model must be configured with `schema='velocity_analytics'` in its config block

## Source Data

Reference source tables using `{{ source('enterprise_db', 'TABLE_NAME') }}` syntax.

### ORDERS table (`{{ source('enterprise_db', 'ORDERS') }}`)
Contains order header information including order_id, customer_id, ordered_at (timestamp), grand_total, and status columns. Explore the table to understand available columns.

### ORDER_LINES table (`{{ source('enterprise_db', 'ORDER_LINES') }}`)
Contains line-level order details including ORDER_LINE_ID, ORDER_ID, PRODUCT_ID, PRODUCT_NAME, QUANTITY_ORDERED, QUANTITY_RETURNED, UNIT_PRICE, DISCOUNT_AMOUNT, and LINE_TOTAL. Explore the table to understand available columns.

### PRODUCTS table (`{{ source('enterprise_db', 'PRODUCTS') }}`)
Contains product information including PRODUCT_ID, PRODUCT_NAME, PRODUCT_TYPE, PRIMARY_CATEGORY_ID (may be NULL), and COST_PRICE (may be NULL). Explore the table to understand available columns.

## Required Models

### 1. Staging Model (`models/staging/stg_order_lines__sales.sql`)

Config: `{{ config(materialized='view') }}`

Join order lines with their parent orders and calculate line-level sales metrics:

| Column | Type | Description |
|--------|------|-------------|
| order_line_id | VARCHAR | Unique line item identifier |
| order_id | VARCHAR | Order identifier |
| product_id | VARCHAR | Product identifier |
| product_name | VARCHAR | Product name |
| sale_date | DATE | Date of the sale (from orders.ordered_at) |
| units_sold | DECIMAL | Quantity ordered minus quantity returned, minimum 0 |
| unit_price | DECIMAL | Unit price |
| gross_line_value | DECIMAL(12,2) | units_sold * unit_price |
| discount_amount | DECIMAL(12,2) | Discount applied (coalesce NULL to 0) |
| net_line_value | DECIMAL(12,2) | gross_line_value - discount_amount |

**Filtering rules**:
- Include only orders from 2024: `ordered_at >= '2024-01-01'` AND `ordered_at < '2025-01-01'`
- **IMPORTANT**: Apply `trim()` to the status column before filtering, excluding orders where `trim(status) IN ('CANCELLED', 'RETURNED', 'FAILED')`
- Exclude lines where units_sold <= 0 (no actual sale occurred)

### 2. Intermediate Model (`models/intermediate/int_product_daily_sales.sql`)

Config: `{{ config(materialized='view') }}`

Aggregate sales data at the product-day level for velocity analysis:

| Column | Type | Description |
|--------|------|-------------|
| product_id | VARCHAR | Product identifier |
| sale_date | DATE | Date of sales |
| daily_units | DECIMAL | Total units sold on this date |
| daily_orders | INTEGER | Number of distinct orders containing this product on this date |
| daily_gross_revenue | DECIMAL(12,2) | Sum of gross_line_value |
| daily_discount | DECIMAL(12,2) | Sum of discount_amount |
| daily_net_revenue | DECIMAL(12,2) | Sum of net_line_value |

### 3. Intermediate Model (`models/intermediate/int_product_monthly_sales.sql`)

Config: `{{ config(materialized='view') }}`

Aggregate sales data at the product-month level:

| Column | Type | Description |
|--------|------|-------------|
| product_id | VARCHAR | Product identifier |
| sale_month | VARCHAR | Month in YYYY-MM format (from sale_date) |
| monthly_units | DECIMAL | Sum of daily_units for the month |
| monthly_orders | INTEGER | Distinct orders for the month |
| monthly_net_revenue | DECIMAL(12,2) | Sum of daily_net_revenue for the month |

### 4. Intermediate Model (`models/intermediate/int_product_sales_metrics.sql`)

Config: `{{ config(materialized='view') }}`

Calculate product-level sales metrics including velocity and trend analysis:

| Column | Type | Description |
|--------|------|-------------|
| product_id | VARCHAR | Product identifier |
| product_name | VARCHAR | Product name (use most frequently occurring **order line rows** for the product_id; if tie, use first alphabetically) |
| total_units_sold | DECIMAL | Sum of all units sold |
| total_orders | INTEGER | Count of distinct orders containing this product |
| total_gross_revenue | DECIMAL(12,2) | Sum of gross_line_value |
| total_discount | DECIMAL(12,2) | Sum of discount_amount |
| total_net_revenue | DECIMAL(12,2) | Sum of net_line_value |
| days_with_sales | INTEGER | Count of distinct dates with sales |
| first_sale_date | DATE | Earliest sale date |
| last_sale_date | DATE | Latest sale date |
| active_days | INTEGER | last_sale_date - first_sale_date + 1 |
| avg_daily_units | DECIMAL(10,2) | total_units_sold / active_days |
| avg_daily_revenue | DECIMAL(12,2) | total_net_revenue / active_days |
| daily_units_std_dev | DECIMAL(10,2) | Population standard deviation of daily_units (NULL if days_with_sales < 2) |
| first_half_units | DECIMAL | Units sold in first half of active period (see calculation) |
| second_half_units | DECIMAL | Units sold in second half of active period (see calculation) |

**Half-Period Calculation**:
For each product, determine the midpoint of its active period:
- `midpoint_date = first_sale_date + (active_days / 2)` (integer division)
- **First half**: Sales where `sale_date < midpoint_date`
- **Second half**: Sales where `sale_date >= midpoint_date`
- Note: For single-day products (active_days = 1), midpoint = first_sale_date, so first_half_units = 0 and second_half_units = total_units_sold

### 5. Mart Model (`models/marts/product_sales_velocity.sql`)

Config: `{{ config(materialized='table', schema='velocity_analytics') }}`

Create a **table** with one row per product containing velocity metrics and classifications:

| # | Column | Type | Description |
|---|--------|------|-------------|
| 1 | product_id | VARCHAR | Product identifier |
| 2 | product_name | VARCHAR | Product name |
| 3 | category_id | VARCHAR | Category identifier ('UNCATEGORIZED' if NULL) |
| 4 | total_units_sold | INTEGER | Total units sold (cast to integer) |
| 5 | total_orders | INTEGER | Distinct orders containing this product |
| 6 | total_gross_revenue | DECIMAL(12,2) | Revenue before discounts |
| 7 | total_net_revenue | DECIMAL(12,2) | Revenue after discounts |
| 8 | total_discount | DECIMAL(12,2) | Total discounts given |
| 9 | avg_unit_price | DECIMAL(10,2) | total_gross_revenue / total_units_sold |
| 10 | discount_rate | DECIMAL(10,2) | (total_discount / total_gross_revenue) * 100, or 0 if no revenue |
| 11 | days_with_sales | INTEGER | Days with at least one sale |
| 12 | first_sale_date | DATE | First sale date |
| 13 | last_sale_date | DATE | Last sale date |
| 14 | active_days | INTEGER | Span of active selling period |
| 15 | sales_frequency | DECIMAL(10,2) | (days_with_sales / active_days) * 100, or 100 if active_days = 1 |
| 16 | avg_daily_units | DECIMAL(10,2) | Average units sold per active day |
| 17 | avg_daily_revenue | DECIMAL(12,2) | Average net revenue per active day |
| 18 | daily_units_std_dev | DECIMAL(10,2) | Std dev of daily units (NULL if days_with_sales < 2) |
| 19 | velocity_cv | DECIMAL(10,2) | Coefficient of variation: (std_dev / avg_daily_units) * 100 (NULL if std_dev is NULL or avg = 0) |
| 20 | first_half_units | INTEGER | Units in first half of active period |
| 21 | second_half_units | INTEGER | Units in second half of active period |
| 22 | velocity_change_ratio | DECIMAL(10,2) | second_half_units / first_half_units (NULL if first_half = 0 or active_days < 2) |
| 23 | revenue_rank | INTEGER | Rank by total_net_revenue DESC (1 = highest), use ROW_NUMBER |
| 24 | velocity_percentile | INTEGER | Percentile 1-100 by avg_daily_units (100 = fastest), use NTILE(100) |
| 25 | velocity_tier | VARCHAR | Tier based on velocity_percentile (see rules) |
| 26 | consistency_tier | VARCHAR | Tier based on velocity_cv (see rules) |
| 27 | velocity_trend | VARCHAR | Trend based on velocity_change_ratio (see rules) |
| 28 | months_active | INTEGER | Distinct months with sales (from monthly model) |
| 29 | first_month_units | INTEGER | Units sold in the earliest month (NULL if months_active < 2) |
| 30 | last_month_units | INTEGER | Units sold in the latest month (NULL if months_active < 2) |
| 31 | month_velocity_change | DECIMAL(10,2) | last_month_units - first_month_units (NULL if months_active < 2) |
| 32 | rolling_3m_avg_units | DECIMAL(10,2) | Avg monthly_units over the latest 3 months (NULL if months_active < 3) |
| 33 | recent_3m_units | DECIMAL(10,2) | Sum of monthly_units over latest 3 months (NULL if months_active < 3) |
| 34 | recent_share_pct | DECIMAL(10,2) | recent_3m_units / total_units_sold * 100 (NULL if months_active < 3 or total_units_sold = 0) |
| 35 | monthly_cv | DECIMAL(10,2) | Stddev/avg of monthly_units * 100 (NULL if months_active < 2 or avg = 0) |
| 36 | category_avg_daily_units | DECIMAL(10,2) | Average avg_daily_units within category |
| 37 | vs_category_velocity | DECIMAL(10,2) | avg_daily_units - category_avg_daily_units |
| 38 | category_velocity_tier | VARCHAR | Relative velocity tier (see rules) |
| 39 | category_velocity_rank | INTEGER | Rank within category by avg_daily_units DESC, use ROW_NUMBER |
| 40 | category_velocity_percentile | INTEGER | Percentile within category 1-100 by avg_daily_units DESC, use NTILE(100) |
| 41 | monthly_trend | VARCHAR | Trend based on month_velocity_change (see rules) |
| 42 | momentum_score | INTEGER | Momentum score 0-100 (see calculation) |
| 43 | momentum_tier | VARCHAR | Tier based on momentum_score (see rules) |
| 44 | seasonality_index | DECIMAL(10,2) | max_monthly_units / avg_monthly_units (NULL if months_active < 2 or avg = 0) |
| 45 | volatility_band | VARCHAR | Band based on CVs (see rules) |
| 46 | demand_pattern | VARCHAR | Multi-factor classification (see rules) |
| 47 | performance_score | INTEGER | Composite score 0-100 (see calculation) |
| 48 | performance_grade | VARCHAR | Grade based on performance_score (see rules) |

### Velocity Tier Classification Rules
Based on velocity_percentile:
- 'Elite' when velocity_percentile >= 95
- 'High' when velocity_percentile >= 75 AND < 95
- 'Medium' when velocity_percentile >= 40 AND < 75
- 'Low' when velocity_percentile >= 15 AND < 40
- 'Minimal' when velocity_percentile < 15

### Consistency Tier Classification Rules
Based on velocity_cv (coefficient of variation):
- 'Very Consistent' when velocity_cv IS NOT NULL AND velocity_cv < 50
- 'Consistent' when velocity_cv >= 50 AND < 100
- 'Variable' when velocity_cv >= 100 AND < 200
- 'Highly Variable' when velocity_cv >= 200
- 'Insufficient Data' when velocity_cv IS NULL

### Velocity Trend Classification Rules
Based on velocity_change_ratio:
- 'Accelerating' when velocity_change_ratio > 1.25 (second half > 25% higher)
- 'Growing' when velocity_change_ratio > 1.05 AND <= 1.25
- 'Stable' when velocity_change_ratio >= 0.95 AND <= 1.05
- 'Slowing' when velocity_change_ratio >= 0.75 AND < 0.95
- 'Declining' when velocity_change_ratio < 0.75
- 'New Product' when velocity_change_ratio IS NULL AND active_days < 30
- 'Insufficient Data' when velocity_change_ratio IS NULL AND active_days >= 30

### Category Velocity Tier Rules
Based on vs_category_velocity:
- 'Above' when vs_category_velocity >= 0.50
- 'Near' when vs_category_velocity > -0.50 AND < 0.50
- 'Below' when vs_category_velocity <= -0.50

### Monthly Trend Rules
Based on month_velocity_change:
- 'Rapid Growth' when month_velocity_change >= 10
- 'Growth' when month_velocity_change >= 3 AND < 10
- 'Stable' when month_velocity_change > -3 AND < 3
- 'Decline' when month_velocity_change <= -3 AND > -10
- 'Rapid Decline' when month_velocity_change <= -10
- 'New' when months_active < 2 (highest priority; month_velocity_change must be NULL)

### Recent Share Rules
- recent_3m_units = sum of monthly_units for the latest 3 months by sale_month
- recent_share_pct = (recent_3m_units / total_units_sold) * 100
- If months_active < 3 or total_units_sold = 0, set recent_3m_units and recent_share_pct to NULL

### Momentum Score (0-100)
Sum of monthly_trend points + velocity_trend points, clamped to 0-100.

Monthly trend points:
- 'Rapid Growth' = 40
- 'Growth' = 30
- 'Stable' = 20
- 'Decline' = 10
- 'Rapid Decline' = 0
- 'New' = 15

Velocity trend points:
- 'Accelerating' = 30
- 'Growing' = 20
- 'Stable' = 15
- 'Slowing' = 8
- 'Declining' = 2
- 'New Product' = 12
- 'Insufficient Data' = 10

### Momentum Tier Rules
Based on momentum_score:
- 'Hot' when momentum_score >= 60
- 'Warm' when momentum_score >= 45 AND < 60
- 'Cool' when momentum_score >= 25 AND < 45
- 'Cold' when momentum_score < 25

### Seasonality Index
- seasonality_index = max_monthly_units / avg_monthly_units
- If months_active < 2 OR avg_monthly_units = 0, set seasonality_index to NULL
- Round to 2 decimal places

### Volatility Band Rules
Let `volatility_cv = COALESCE(monthly_cv, velocity_cv)`.
- 'Insufficient' when volatility_cv IS NULL
- 'Highly Volatile' when volatility_cv >= 200
- 'Volatile' when volatility_cv >= 100 AND < 200
- 'Moderate' when volatility_cv >= 50 AND < 100
- 'Stable' when volatility_cv < 50

### Demand Pattern Rules
Evaluate in the order shown below (first match wins):
1. 'Breakout' when velocity_tier IN ('Elite','High') AND monthly_trend IN ('Rapid Growth','Growth') AND consistency_tier IN ('Very Consistent','Consistent')
2. 'Seasonal' when monthly_cv >= 150 AND months_active >= 4
3. 'Steady' when velocity_trend IN ('Stable','Growing') AND monthly_trend = 'Stable'
4. 'Fading' when velocity_trend IN ('Declining','Slowing') AND monthly_trend IN ('Decline','Rapid Decline')
5. 'New Entry' when monthly_trend = 'New'
6. 'Long Tail' when velocity_tier IN ('Low','Minimal') AND consistency_tier IN ('Variable','Highly Variable')
7. 'Unclassified' otherwise

### Performance Score Calculation (0-100)
A composite score combining four components:

1. **Revenue Component (0-35 points)**: Based on revenue_rank percentile position
   - Calculate: `35 * (1 - (revenue_rank - 1) / NULLIF(total_products - 1, 0))`
   - If only 1 product, give 35 points
   - Round to nearest integer

2. **Velocity Component (0-25 points)**: Based on velocity_tier
   - 'Elite' = 25, 'High' = 20, 'Medium' = 15, 'Low' = 8, 'Minimal' = 3

3. **Consistency Component (0-20 points)**: Based on consistency_tier
   - 'Very Consistent' = 20, 'Consistent' = 16, 'Variable' = 10, 'Highly Variable' = 4, 'Insufficient Data' = 10

4. **Monthly Trend Component (0-20 points)**: Based on monthly_trend
   - 'Rapid Growth' = 20, 'Growth' = 16, 'Stable' = 12, 'Decline' = 6, 'Rapid Decline' = 2, 'New' = 10

**Final Score**: Sum of all four components, clamped to 0-100, cast to INTEGER.

### Performance Grade Rules
Based on performance_score:
- 'A' when performance_score >= 80
- 'B' when performance_score >= 65 AND < 80
- 'C' when performance_score >= 50 AND < 65
- 'D' when performance_score >= 35 AND < 50
- 'F' when performance_score < 35

## Output Requirements

1. **Model Names**: All five models must exist with exact names specified
2. **Schema**: The mart model must use schema='velocity_analytics' in its config
3. **Materialization**: The mart model must be materialized as TABLE (not view)
4. **Column Order**: Columns must appear in the exact order specified (48 columns total in mart)
5. **Data Types**:
   - Monetary values rounded to 2 decimal places
   - Percentages rounded to 2 decimal places
   - Ranks and scores must be INTEGER type
   - velocity_tier must be exactly one of: 'Elite', 'High', 'Medium', 'Low', 'Minimal'
   - consistency_tier must be exactly one of: 'Very Consistent', 'Consistent', 'Variable', 'Highly Variable', 'Insufficient Data'
   - velocity_trend must be exactly one of: 'Accelerating', 'Growing', 'Stable', 'Slowing', 'Declining', 'New Product', 'Insufficient Data'
   - category_velocity_tier must be exactly one of: 'Above', 'Near', 'Below'
   - monthly_trend must be exactly one of: 'Rapid Growth', 'Growth', 'Stable', 'Decline', 'Rapid Decline', 'New'
    - momentum_tier must be exactly one of: 'Hot', 'Warm', 'Cool', 'Cold'
    - volatility_band must be exactly one of: 'Insufficient', 'Highly Volatile', 'Volatile', 'Moderate', 'Stable'
   - demand_pattern must be exactly one of: 'Breakout', 'Seasonal', 'Steady', 'Fading', 'New Entry', 'Long Tail', 'Unclassified'
   - performance_grade must be exactly one of: 'A', 'B', 'C', 'D', 'F'
6. **Idempotency**: Multiple dbt runs must produce identical results

## Technical Notes
- Handle NULL values explicitly (see rules for NULL behavior)
- Ensure deterministic results across multiple runs using consistent tie-breaking
- Use product_id ASC as a secondary sort for revenue_rank and velocity_percentile
- For category rankings, use avg_daily_units DESC, then product_id ASC
- For NTILE percentiles, higher percentile = higher avg_daily_units (100 = fastest)
- When calculating half-period metrics, use integer division for midpoint calculation

## Guidelines

- The SQL syntax should work on both DuckDB and Snowflake (ANSI SQL compatible)
