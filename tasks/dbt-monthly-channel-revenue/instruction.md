# Monthly Channel Revenue Analysis

Build dbt models that analyze sales performance across different order channels (WEB, MOBILE, POS, etc.) on a monthly basis. This task requires aggregating by multiple dimensions, calculating month-over-month growth per channel, ranking channels by performance, classifying growth trends, computing market benchmarks, and deriving advanced analytics metrics.

## Your Task

Add dbt models to the existing dbt project that create a comprehensive monthly channel performance analysis with market-level benchmarking.

## Files
- DuckDB: `/app/dbt_models_duckdb/models/` (for new models)
- Snowflake: `/app/dbt_models_snowflake/models/` (for new models)
- **Target schema for mart model**: `channel_analytics` (will appear as `main_channel_analytics`)

Run `dbt deps` before `dbt run`.

## Source Data

### ORDERS table (`ORDERS.ORDERS` via `{{ source('enterprise_db', 'ORDERS') }}`)
| Column | Type | Description |
|--------|------|-------------|
| order_id | VARCHAR | Unique order identifier |
| customer_id | VARCHAR | Customer identifier |
| ordered_at | TIMESTAMP | Order timestamp |
| grand_total | DECIMAL | Order total amount |
| status | VARCHAR | Order status (may contain whitespace) |
| order_source | VARCHAR | Channel: WEB, MOBILE, POS, MARKETPLACE, PHONE |

## Required Models

### 1. Staging Model (`models/staging/stg_orders__channel.sql`)
Config: `{{ config(materialized='view') }}`

- Filter orders to year 2024: `ordered_at >= '2024-01-01'` AND `ordered_at < '2025-01-01'`
- Exclude cancelled and returned orders (status values: 'CANCELLED', 'RETURNED')
- Exclude orders with NULL order_source
- Clean string columns by trimming whitespace
- Include columns: order_id, customer_id, ordered_at, grand_total, order_source

### 2. Intermediate Model (`models/intermediate/int_monthly_channel_metrics.sql`)
Config: `{{ config(materialized='view') }}`

Aggregate orders by month and channel:

| Column | Type | Description |
|--------|------|-------------|
| month_start | DATE | First day of the month |
| channel | VARCHAR | Order source (WEB, MOBILE, etc.) |
| order_count | INTEGER | Number of orders |
| unique_customers | INTEGER | Distinct customers who ordered |
| total_revenue | DECIMAL(12,2) | Sum of grand_total, rounded to 2 decimal places |
| avg_order_value | DECIMAL(12,2) | total_revenue / order_count, rounded to 2 decimal places |

### 3. Intermediate Model (`models/intermediate/int_monthly_market_benchmarks.sql`)
Config: `{{ config(materialized='view') }}`

Calculate market-level benchmarks for each month (across all channels):

| Column | Type | Description |
|--------|------|-------------|
| month_start | DATE | First day of the month |
| total_market_revenue | DECIMAL(14,2) | Sum of revenue across all channels |
| total_market_orders | INTEGER | Sum of orders across all channels |
| total_market_customers | INTEGER | Sum of unique customers across all channels (NOT distinct across channels) |
| channel_count | INTEGER | Number of active channels this month |
| market_avg_revenue | DECIMAL(12,2) | total_market_revenue / channel_count |
| market_avg_orders | DECIMAL(10,2) | total_market_orders / channel_count |
| market_avg_aov | DECIMAL(12,2) | total_market_revenue / total_market_orders |
| market_median_revenue | DECIMAL(12,2) | Median of channel revenues for this month |
| revenue_hhi | DECIMAL(8,4) | Herfindahl-Hirschman Index: sum of (market_share/100)^2 for all channels |

**HHI Calculation**: For each month, calculate the sum of squared market shares. Market share = (channel_revenue / total_market_revenue) * 100. HHI = sum((share/100)^2) for all channels. Range is 0 to 1, where 1 = perfect monopoly.

### 4. Mart Model (`models/marts/channel/monthly_channel_performance.sql`)
Config: `{{ config(materialized='table', schema='channel_analytics') }}`

Create a **table** with channel performance metrics, containing these columns in EXACT order:

| # | Column | Type | Description |
|---|--------|------|-------------|
| 1 | month_start | DATE | First day of the month |
| 2 | channel | VARCHAR | Order source |
| 3 | quarter | VARCHAR | Quarter identifier: 'Q1', 'Q2', 'Q3', or 'Q4' |
| 4 | order_count | INTEGER | Orders this month for this channel |
| 5 | unique_customers | INTEGER | Unique customers this month for this channel |
| 6 | total_revenue | DECIMAL(12,2) | Revenue this month for this channel |
| 7 | avg_order_value | DECIMAL(12,2) | Average order value |
| 8 | prev_month_revenue | DECIMAL(12,2) | Same channel's revenue in previous month (NULL for first appearance) |
| 9 | revenue_mom_change | DECIMAL(12,2) | total_revenue minus prev_month_revenue (NULL if no previous) |
| 10 | revenue_mom_pct | DECIMAL(8,2) | Percentage change: ((current - prev) / prev) * 100 (NULL if no previous or prev is 0) |
| 11 | growth_category | VARCHAR | Trend classification (see rules below) |
| 12 | channel_tenure | INTEGER | Months this channel has appeared (1 for first month) |
| 13 | rolling_3m_revenue | DECIMAL(12,2) | Average of current + 2 prior months (NULL until 3 months) |
| 14 | monthly_total_revenue | DECIMAL(12,2) | Total revenue across ALL channels for this month |
| 15 | market_share_pct | DECIMAL(6,2) | (channel revenue / monthly total) * 100 |
| 16 | market_share_change | DECIMAL(6,2) | Change in market_share_pct from previous month (NULL for first appearance) |
| 17 | channel_rank | INTEGER | Rank by revenue within month (1 = highest, use RANK()) |
| 18 | prev_month_rank | INTEGER | This channel's rank in the previous month (NULL for first appearance) |
| 19 | rank_change | INTEGER | prev_month_rank minus channel_rank (positive = improved, NULL for first) |
| 20 | consecutive_growth_months | INTEGER | Count of consecutive months with positive revenue_mom_pct (0 if current is not positive, resets on negative/zero growth) |
| 21 | performance_tier | VARCHAR | Classification based on market_share_pct AND growth (see rules below) |
| 22 | is_top_channel | VARCHAR(1) | 'Y' if channel_rank = 1, 'N' otherwise |
| 23 | ytd_revenue | DECIMAL(14,2) | Cumulative year-to-date revenue for this channel |
| 24 | ytd_order_count | INTEGER | Cumulative year-to-date order count for this channel |
| 25 | pct_of_ytd_revenue | DECIMAL(6,2) | (total_revenue / ytd_revenue) * 100 - what % of YTD came from this month |
| 26 | qtd_revenue | DECIMAL(14,2) | Cumulative quarter-to-date revenue for this channel (resets each quarter) |
| 27 | growth_acceleration | DECIMAL(10,2) | Change in revenue_mom_pct from previous month (NULL for first 2 months) |
| 28 | revenue_volatility | DECIMAL(8,2) | Coefficient of variation of last 3 months revenue: (stddev / avg) * 100, NULL until 3 months |
| 29 | prev_month_customers | INTEGER | Unique customers in previous month (NULL for first appearance) |
| 30 | customer_growth_rate | DECIMAL(8,2) | ((unique_customers - prev_month_customers) / prev_month_customers) * 100 (NULL if no prev or prev = 0) |
| 31 | market_avg_revenue | DECIMAL(12,2) | Average revenue across all channels for this month (from benchmarks) |
| 32 | vs_market_revenue_pct | DECIMAL(8,2) | ((total_revenue - market_avg_revenue) / market_avg_revenue) * 100 |
| 33 | market_avg_aov | DECIMAL(12,2) | Market average AOV for this month |
| 34 | vs_market_aov_pct | DECIMAL(8,2) | ((avg_order_value - market_avg_aov) / market_avg_aov) * 100 |
| 35 | aov_rank | INTEGER | Rank by avg_order_value within month (1 = highest, use RANK()) |
| 36 | revenue_hhi | DECIMAL(8,4) | Market concentration HHI for this month (same for all channels in month) |
| 37 | growth_consistency_score | INTEGER | Count of months with positive growth in last 6 months (0-6), 0 for tenure < 2 |
| 38 | channel_momentum_score | INTEGER | Composite score 0-100 based on growth, market share, and ranking (see calculation) |
| 39 | channel_efficiency_score | INTEGER | Composite score 0-100 based on AOV, customer growth, and consistency (see calculation) |
| 40 | strategic_recommendation | VARCHAR | Strategic action recommendation (see rules below) |

### Quarter Assignment (Column 3)
Based on month_start:
- 'Q1' for months 1-3 (January, February, March)
- 'Q2' for months 4-6 (April, May, June)
- 'Q3' for months 7-9 (July, August, September)
- 'Q4' for months 10-12 (October, November, December)

### Growth Category Rules (Column 11)
Classify based on revenue_mom_pct using these EXACT thresholds:
- `'Explosive'` when revenue_mom_pct >= 100
- `'Strong Growth'` when revenue_mom_pct >= 50 and < 100
- `'Moderate Growth'` when revenue_mom_pct >= 20 and < 50
- `'Slight Growth'` when revenue_mom_pct > 0 and < 20
- `'Stable'` when revenue_mom_pct = 0 exactly
- `'Slight Decline'` when revenue_mom_pct < 0 and > -20
- `'Moderate Decline'` when revenue_mom_pct <= -20 and > -50
- `'Sharp Decline'` when revenue_mom_pct <= -50
- NULL for the first month each channel appears

### Performance Tier Rules (Column 21)
Classify based on BOTH market_share_pct AND growth_category:
- `'Market Leader'` when market_share_pct >= 40 AND growth_category IN ('Explosive', 'Strong Growth', 'Moderate Growth')
- `'Strong Performer'` when market_share_pct >= 25 AND market_share_pct < 40 AND growth_category NOT IN ('Sharp Decline', 'Moderate Decline')
- `'Growth Potential'` when market_share_pct < 25 AND growth_category IN ('Explosive', 'Strong Growth')
- `'Stable Core'` when growth_category IN ('Stable', 'Slight Growth', 'Slight Decline') AND market_share_pct >= 10
- `'At Risk'` when growth_category IN ('Moderate Decline', 'Sharp Decline')
- `'Emerging'` when channel_tenure <= 2 AND growth_category IS NULL
- `'Niche'` for all other cases
- NULL for first month of each channel (when growth_category is NULL and channel_tenure > 2 should not happen)

### Consecutive Growth Months (Column 20)
- Count how many months IN A ROW this channel has had positive growth (revenue_mom_pct > 0)
- Reset to 0 when revenue_mom_pct <= 0 or NULL
- First month = 0 (no prior month to compare)
- Example: If a channel has mom_pct of [NULL, 10, 25, -5, 15, 30], consecutive would be [0, 1, 2, 0, 1, 2]

### Rank Change (Column 19)
- Calculate as: prev_month_rank - channel_rank
- Positive value means the channel moved UP in rankings (improved)
- Negative value means the channel moved DOWN in rankings (declined)
- Example: If prev_rank=3, current_rank=1, then rank_change = 3-1 = 2 (improved by 2 positions)

### YTD Metrics (Columns 23-25)
- **ytd_revenue**: Sum of total_revenue for this channel from January through current month
- **ytd_order_count**: Sum of order_count for this channel from January through current month
- **pct_of_ytd_revenue**: (total_revenue / ytd_revenue) * 100, rounded to 2 decimal places

### QTD Revenue (Column 26)
- **qtd_revenue**: Cumulative sum of total_revenue for this channel within the current quarter
- Resets at the start of each quarter (Q1=Jan, Q2=Apr, Q3=Jul, Q4=Oct)
- Use a window function partitioned by channel AND quarter

### Growth Acceleration (Column 27)
- Calculate as: current revenue_mom_pct minus previous month's revenue_mom_pct
- NULL for first 2 months of each channel (need 2 prior months to calculate first mom_pct change)
- Positive value = growth is accelerating
- Negative value = growth is decelerating
- Example: If mom_pct goes from 10% to 25%, acceleration = 25 - 10 = 15

### Revenue Volatility (Column 28)
- Coefficient of variation of the last 3 months' revenue
- Calculate as: (STDDEV_POP of last 3 months revenue / AVG of last 3 months revenue) * 100
- NULL until channel has 3 months of data
- Lower values indicate more stable revenue; higher values indicate more volatile

### Customer Growth Rate (Column 30)
- Calculate as: ((unique_customers - prev_month_customers) / prev_month_customers) * 100
- NULL for first month of each channel (no previous customers)
- NULL if prev_month_customers = 0

### Growth Consistency Score (Column 37)
- Count the number of months with positive growth (revenue_mom_pct > 0) in the last 6 months
- Range: 0-6
- For channels with tenure < 2, value is 0
- For channels with tenure 2-6, count positive months in available history
- Example: If last 6 months mom_pct = [10, -5, 20, 30, -10, 15], score = 4 (four positive months)

### Channel Momentum Score (Column 38)
A composite score from 0-100 combining three components:

1. **Growth Component (0-40 points)**: Based on revenue_mom_pct
   - revenue_mom_pct >= 50 = 40 points
   - revenue_mom_pct >= 20 = 30 points
   - revenue_mom_pct >= 0 = 20 points
   - revenue_mom_pct >= -20 = 10 points
   - revenue_mom_pct < -20 = 0 points
   - NULL mom_pct = 20 points (neutral)

2. **Market Share Component (0-35 points)**: Based on market_share_pct
   - market_share_pct >= 40 = 35 points
   - market_share_pct >= 25 = 28 points
   - market_share_pct >= 15 = 21 points
   - market_share_pct >= 10 = 14 points
   - market_share_pct < 10 = 7 points

3. **Ranking Component (0-25 points)**: Based on channel_rank
   - channel_rank = 1 = 25 points
   - channel_rank = 2 = 20 points
   - channel_rank = 3 = 15 points
   - channel_rank = 4 = 10 points
   - channel_rank >= 5 = 5 points

**Final Score**: Sum of all three components as an integer (0-100)

### Channel Efficiency Score (Column 39)
A composite score from 0-100 combining three different components:

1. **AOV Component (0-40 points)**: Based on aov_rank
   - aov_rank = 1 = 40 points
   - aov_rank = 2 = 32 points
   - aov_rank = 3 = 24 points
   - aov_rank = 4 = 16 points
   - aov_rank >= 5 = 8 points

2. **Customer Growth Component (0-35 points)**: Based on customer_growth_rate
   - customer_growth_rate >= 50 = 35 points
   - customer_growth_rate >= 20 = 28 points
   - customer_growth_rate >= 0 = 21 points
   - customer_growth_rate >= -20 = 14 points
   - customer_growth_rate < -20 = 7 points
   - NULL customer_growth_rate = 21 points (neutral)

3. **Consistency Component (0-25 points)**: Based on growth_consistency_score
   - growth_consistency_score >= 5 = 25 points
   - growth_consistency_score >= 4 = 20 points
   - growth_consistency_score >= 3 = 15 points
   - growth_consistency_score >= 2 = 10 points
   - growth_consistency_score < 2 = 5 points

**Final Score**: Sum of all three components as an integer (0-100)

### Strategic Recommendation Rules (Column 40)
Based on performance_tier, channel_momentum_score, channel_efficiency_score, and consecutive_growth_months. **Evaluate conditions in the order shown (first match wins)**:
- `'Invest Heavily'` when channel_momentum_score >= 80 AND channel_efficiency_score >= 70 AND consecutive_growth_months >= 3
- `'Scale Up'` when performance_tier = 'Market Leader' OR (channel_momentum_score >= 70 AND market_share_pct >= 20)
- `'Optimize'` when performance_tier IN ('Strong Performer', 'Stable Core') AND channel_momentum_score >= 50 AND channel_efficiency_score >= 50
- `'Experiment'` when performance_tier = 'Growth Potential' OR (performance_tier = 'Emerging' AND channel_momentum_score >= 40)
- `'Maintain'` when performance_tier IN ('Stable Core', 'Niche') AND consecutive_growth_months >= 1
- `'Divest'` when performance_tier = 'At Risk' AND consecutive_growth_months = 0 AND channel_momentum_score < 20 AND channel_efficiency_score < 30
- `'Review'` when performance_tier = 'At Risk' OR channel_momentum_score < 30
- `'Monitor'` for all other cases

## Output Requirements

1. **Model Names**: All four models must exist with exact names specified:
   - `stg_orders__channel` (staging)
   - `int_monthly_channel_metrics` (intermediate)
   - `int_monthly_market_benchmarks` (intermediate)
   - `monthly_channel_performance` (mart)
2. **Materialization**: The mart model must be materialized as TABLE (not view)
3. **Column Order**: Columns must appear in the EXACT order specified (40 columns total)
4. **Data Types**:
   - month_start must be DATE type (not TIMESTAMP)
   - Monetary values rounded to 2 decimal places
   - Percentages rounded to 2 decimal places
   - is_top_channel must be exactly 'Y' or 'N'
   - quarter must be exactly one of: 'Q1', 'Q2', 'Q3', 'Q4'
   - channel_momentum_score must be INTEGER (0-100)
   - channel_efficiency_score must be INTEGER (0-100)
   - growth_consistency_score must be INTEGER (0-6)
   - String classifications must match EXACTLY (case-sensitive)
   - strategic_recommendation must be one of: 'Invest Heavily', 'Scale Up', 'Optimize', 'Experiment', 'Maintain', 'Review', 'Divest', 'Monitor'
5. **NULL Handling**:
   - First month each channel appears: NULL for prev_month_revenue, revenue_mom_change, revenue_mom_pct, growth_category, market_share_change, prev_month_rank, rank_change, growth_acceleration
   - First 2 months each channel appears: NULL for rolling_3m_revenue, growth_acceleration
   - First 2 months each channel appears: NULL for revenue_volatility (needs 3 months of data to compute)
   - Division by zero must produce NULL
   - consecutive_growth_months should be 0 (not NULL) for first month
   - pct_of_ytd_revenue should never be NULL (ytd_revenue always >= total_revenue)
6. **Ordering**: Results ordered by month_start ASC, then by channel_rank ASC
7. **Completeness**: Only include channel-month combinations that have orders
8. **Idempotency**: Multiple dbt runs must produce identical results

## Technical Notes
- Use DuckDB-compatible SQL syntax
- Window functions must track each channel separately using PARTITION BY channel ORDER BY month_start
- Use RANK() (not ROW_NUMBER() or DENSE_RANK()) for channel rankings
- Ensure all calculations are deterministic
- Use `{{ source('enterprise_db', 'ORDERS') }}` to reference the orders table

**Note**: If your models appear in a different schema than expected, re-check your work and review how dbt handles schema naming when a custom schema is specified.

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
