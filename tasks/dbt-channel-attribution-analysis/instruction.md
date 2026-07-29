# Channel Attribution Analysis

Build dbt models that analyze sales performance across different sales channels, understand customer acquisition patterns, measure cross-channel shopping behavior, and compute channel engagement scores.

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
- **Target schema**: `channel_analytics` (will appear as `main_channel_analytics` in database)

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
- Profile pointing to the database
- Source definitions for `enterprise_db` schema

**Important**:
- Run `dbt deps` before `dbt run` to install dependencies
- Use `{{ source('enterprise_db', 'TABLE_NAME') }}` syntax to reference source tables
- Set the schema in your model configs or use the default profile schema

## Source Data

Reference source tables using `{{ source('enterprise_db', 'TABLE_NAME') }}` syntax.

### ORDERS table (`{{ source('enterprise_db', 'ORDERS') }}`)
Contains order records with fields such as order_id, customer_id, channel_id, ordered_at, grand_total, and status. Explore the table to understand available columns and their types.

### CHANNELS table (`{{ source('enterprise_db', 'CHANNELS') }}`)
Contains channel definitions with fields such as CHANNEL_ID, CHANNEL_NAME, and CHANNEL_TYPE. Explore the table to understand available columns.

## Required Models

### 1. Staging Model (`models/staging/stg_orders__channels.sql`)
Join orders with their channel information and filter to the analysis period.

Required columns: order_id, customer_id, channel_id, channel_name, channel_type, order_date (DATE type), order_month (first day of month), grand_total.

**Filtering rules**:
- Include only orders from 2024: `ordered_at >= '2024-01-01'` AND `ordered_at < '2025-01-01'`
- Exclude cancelled, returned, and failed orders: trim whitespace from status before checking against 'CANCELLED', 'RETURNED', 'FAILED'
- Only include orders with a valid channel_id (channel_id IS NOT NULL)

### 2. Intermediate Model (`models/intermediate/int_customer_channel_first_touch.sql`)
Identify each customer's first order and their acquisition channel.

Required columns: customer_id, first_channel_id, first_channel_name, first_order_date, first_order_value, total_orders (INTEGER), total_spend (DECIMAL(12,2)), distinct_channels_used (INTEGER), is_cross_channel (VARCHAR(1) - 'Y' or 'N'), customer_lifespan_days (INTEGER - days between first and last order, 0 if only 1 order).

### 3. Mart Model (`models/marts/channel_performance.sql`)
Create a **table** with one row per channel containing performance metrics, with these columns in exact order:

| Column | Type | Description |
|--------|------|-------------|
| channel_id | VARCHAR | Channel identifier |
| channel_name | VARCHAR | Channel name |
| channel_type | VARCHAR | Channel type |
| total_orders | INTEGER | Total number of orders through this channel |
| total_revenue | DECIMAL(12,2) | Sum of grand_total for all orders |
| unique_customers | INTEGER | Number of unique customers who ordered through this channel |
| new_customers_acquired | INTEGER | Customers whose first-ever order (in 2024) was through this channel |
| avg_order_value | DECIMAL(10,2) | total_revenue / total_orders |
| orders_per_customer | DECIMAL(8,2) | total_orders / unique_customers |
| revenue_per_customer | DECIMAL(10,2) | total_revenue / unique_customers |
| revenue_share_pct | DECIMAL(5,2) | Percentage of total revenue from this channel |
| order_share_pct | DECIMAL(5,2) | Percentage of total orders from this channel |
| customer_share_pct | DECIMAL(5,2) | Percentage of acquired customers from this channel |
| revenue_rank | INTEGER | Rank by total_revenue (1 = highest) |
| channel_efficiency | VARCHAR | Efficiency classification (see rules below) |
| acquisition_strength | VARCHAR | Customer acquisition strength classification (see rules below) |
| channel_index | DECIMAL(5,2) | Ratio of revenue share to order share |
| cross_channel_customers | INTEGER | Customers acquired by this channel who also shop on other channels |
| cross_channel_rate | DECIMAL(5,2) | Percentage of acquired customers who become cross-channel shoppers |
| avg_customer_lifespan | DECIMAL(8,2) | Average days between first and last order for customers acquired by this channel |
| channel_engagement_score | INTEGER | Composite engagement score 0-100 (see calculation below) |
| engagement_tier | VARCHAR | Engagement tier classification (see rules below) |

### Channel Efficiency Classification Rules
Compare each channel's average order value to the overall average order value across all channels:
- 'High Efficiency' when the channel's avg_order_value is >= 1.2 times the overall average
- 'Average Efficiency' when the channel's avg_order_value is between 0.8 and 1.2 times the overall average
- 'Low Efficiency' when the channel's avg_order_value is < 0.8 times the overall average

### Acquisition Strength Classification Rules
Based on customer_share_pct (percentage of new customers acquired through this channel):
- 'Primary Acquisition' when customer_share_pct >= 40
- 'Secondary Acquisition' when customer_share_pct >= 20 AND < 40
- 'Supplementary' when customer_share_pct < 20

### Channel Index Calculation
Measures how revenue contribution compares to order volume contribution:
- Calculate as: revenue_share_pct / order_share_pct
- Round to 2 decimal places

### Channel Engagement Score Calculation (0-100)
A composite score combining four components:

1. **Revenue Contribution Component (0-30 points)**: Based on the channel's position in revenue distribution
   - Channel with highest revenue share gets 30 points
   - Channel with lowest revenue share gets 0 points
   - Scale linearly for channels in between based on their percentile position

2. **Customer Acquisition Component (0-25 points)**: Based on customer_share_pct
   - customer_share_pct >= 50 = 25 points
   - customer_share_pct >= 30 = 20 points
   - customer_share_pct >= 15 = 15 points
   - customer_share_pct >= 5 = 10 points
   - customer_share_pct < 5 = 5 points

3. **Cross-Channel Component (0-25 points)**: Based on cross_channel_rate
   - Channels that create cross-channel shoppers are valuable
   - cross_channel_rate >= 40 = 25 points
   - cross_channel_rate >= 25 = 20 points
   - cross_channel_rate >= 15 = 15 points
   - cross_channel_rate >= 5 = 10 points
   - cross_channel_rate < 5 = 5 points

4. **Loyalty Component (0-20 points)**: Based on orders_per_customer
   - orders_per_customer >= 3 = 20 points
   - orders_per_customer >= 2 = 15 points
   - orders_per_customer >= 1.5 = 10 points
   - orders_per_customer < 1.5 = 5 points

**Final Score**: Sum of all four components as an integer (minimum 5, maximum 100)

### Engagement Tier Rules
Based on channel_engagement_score:
- 'Elite' when score >= 80
- 'Strong' when score >= 60 AND < 80
- 'Moderate' when score >= 40 AND < 60
- 'Emerging' when score < 40

## Output Requirements

1. **Model Names**: All three models must exist with exact names specified
2. **Materialization**: The mart model must be materialized as TABLE (not view)
3. **Column Order**: Columns must appear in the exact order specified (22 columns total)
4. **Data Types**:
   - Monetary values rounded to 2 decimal places
   - Percentages rounded to 2 decimal places
   - Ranks must be INTEGER type
   - channel_efficiency must be exactly 'High Efficiency', 'Average Efficiency', or 'Low Efficiency'
   - acquisition_strength must be exactly 'Primary Acquisition', 'Secondary Acquisition', or 'Supplementary'
   - channel_engagement_score must be INTEGER between 0 and 100
   - engagement_tier must be exactly 'Elite', 'Strong', 'Moderate', or 'Emerging'
5. **Ordering**: Results ordered by total_revenue descending (highest revenue channels first)
6. **Idempotency**: Multiple dbt runs must produce identical results

## Technical Notes
- For first-touch attribution, use the earliest order_date for each customer to determine their acquisition channel
- In case of ties (multiple orders on the same first date), use the order with the smallest order_id
- Ensure deterministic results across multiple runs
- Cross-channel customers are those acquired by a channel who have placed orders on at least one other channel
- **IMPORTANT - Column Names**: All output column names must be **lowercase** (e.g., `channel_id`, `channel_name`, `channel_type`). Source tables may have uppercase column names (e.g., `CHANNEL_ID`), so you must explicitly alias them to lowercase in your SELECT statements using `AS column_name`.

**Schema Configuration Note (IMPORTANT)**: On Snowflake, all models must materialize in the **MAIN** schema (the default schema from the profile). dbt's default behavior concatenates the profile schema with any custom schema (e.g., producing `MAIN_CHANNEL_ANALYTICS` instead of `MAIN`), which will cause tests to fail. You **must** override the `generate_schema_name` macro to return only the default schema. Create the file `macros/utils/generate_schema_name.sql` (overwriting any existing one) with a macro that ignores the custom schema and always returns the default schema:

```sql
{% macro generate_schema_name(custom_schema_name, node) -%}
    {{ default_schema }}
{%- endmacro %}
```

This ensures all models (staging, intermediate, and mart) land in the `MAIN` schema where the test verifier expects them.

## Guidelines

- The SQL syntax should work on both DuckDB and Snowflake (ANSI SQL compatible)
- Use CAST() for explicit type casting
- Use DATEDIFF function for date differences (compatible with both backends)
- Use DATE_TRUNC for date truncation
