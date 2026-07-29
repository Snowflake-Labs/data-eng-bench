# Weekly Sales Trend with Growth Metrics

Build dbt models that aggregate sales data by week and calculate week-over-week growth metrics. This task requires proper date handling, window functions, and careful treatment of edge cases.

## Database Backend
This task supports both DuckDB and Snowflake. **Run `echo $DB_TYPE` in a shell BEFORE you write any code or spawn any subagents — the live env determines which backend the verifier runs against.** Do NOT assume a default from this prose. Reference dbt projects exist at `/app/dbt_models_duckdb/` and `/app/dbt_models_snowflake/` for inspection only. Write your dbt project at `/app/dbt_project` — outputs in the reference directories are not graded.

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
- Create a `profiles.yml` in the dbt project directory with profile name `dbt_project`
- Set `DBT_PROFILES_DIR` environment variable to the directory containing `profiles.yml`

### DuckDB Profile
Configure with `type: duckdb` and the database path from `$DUCKDB_PATH`.

### Snowflake Profile
Configure with `type: snowflake` using password authentication:
- Use the environment variables for account, user, password, database, schema, warehouse, and role

## Data Environment
- **Analysis period**: January 1, 2024 to June 30, 2024 (H1 2024)

## Project Setup
- **Project location**: `/app/dbt_project`
- **Schema**: `sales_analytics`

**Configuration Note**: Set the schema only in `profiles.yml`. Do not add `+schema` in `dbt_project.yml`.

## Source Data

### orders table (`main.orders`)
| Column | Type | Description |
|--------|------|-------------|
| order_id | VARCHAR | Unique order identifier |
| customer_id | VARCHAR | Customer identifier |
| ordered_at | TIMESTAMP | Order timestamp |
| grand_total | DECIMAL | Order total amount |
| status | VARCHAR | Order status (may contain leading/trailing whitespace) |

## Required Models

### 1. Staging Model (`models/staging/stg_orders__weekly.sql`)
- Filter orders to H1 2024: `ordered_at >= '2024-01-01'` AND `ordered_at < '2024-07-01'`
- Exclude cancelled, returned, and failed orders: trim whitespace from status before checking against 'CANCELLED', 'RETURNED', 'FAILED'
- Include columns: order_id, customer_id, ordered_at, grand_total (trim string columns)

### 2. Intermediate Model (`models/intermediate/int_weekly_sales.sql`)
Aggregate orders by week using **Sunday-based weeks** (week starts on Sunday):

| Column | Type | Description |
|--------|------|-------------|
| week_start | DATE | First day of the week (Sunday) |
| week_number | INTEGER | Sequential week number starting from 1 for the first week |
| order_count | INTEGER | Number of orders in the week |
| unique_customers | INTEGER | Distinct customers who ordered |
| total_revenue | DECIMAL(12,2) | Sum of grand_total, rounded to 2 decimal places |
| avg_order_value | DECIMAL(12,2) | total_revenue / order_count, rounded to 2 decimal places |

**Important**: Weeks must start on Sunday, not Monday. DuckDB's default `date_trunc('week', ...)` returns Monday - you must adjust for Sunday-based weeks. Note: Sunday-based truncation of dates early in the period (e.g., Jan 1, 2024, which is a Monday) will produce a week_start of Dec 31, 2023 (the preceding Sunday). This is expected — include this week in the output.

### 3. Mart Model (`models/marts/weekly_sales_growth.sql`)
Create a **table** with growth metrics, containing these columns in exact order:

| Column | Type | Description |
|--------|------|-------------|
| week_start | DATE | First day of the week (Sunday) |
| week_number | INTEGER | Sequential week number (1-based) |
| order_count | INTEGER | Orders this week |
| unique_customers | INTEGER | Unique customers this week |
| total_revenue | DECIMAL(12,2) | Revenue this week |
| avg_order_value | DECIMAL(12,2) | Average order value |
| prev_week_revenue | DECIMAL(12,2) | Previous week's revenue (NULL for first week) |
| revenue_change | DECIMAL(12,2) | total_revenue minus prev_week_revenue (NULL for first week) |
| revenue_growth_pct | DECIMAL(8,2) | Percentage change: (revenue_change / prev_week_revenue) * 100 (NULL for first week or if prev is 0) |
| growth_status | VARCHAR | Trend classification (see rules below) |
| rolling_4wk_avg_revenue | DECIMAL(12,2) | Average revenue over current and previous 3 weeks (NULL until week 4) |
| cumulative_revenue | DECIMAL(12,2) | Running total of revenue from week 1 to current week |
| is_best_week | VARCHAR(1) | 'Y' if this week's revenue is the highest seen so far, 'N' otherwise |

### Growth Status Rules
- 'Strong Growth' when revenue_growth_pct >= 50
- 'Growing' when revenue_growth_pct > 0 and < 50
- 'Stable' when revenue_growth_pct = 0 exactly
- 'Declining' when revenue_growth_pct < 0 and > -50
- 'Sharp Decline' when revenue_growth_pct <= -50
- NULL for the first week

### Window Function Requirements
- Previous week revenue: Use window function to get prior week's value
- Rolling average: Calculate over 4-week window (current + 3 preceding), only show when 4 weeks of data available
- Cumulative revenue: Running sum ordered by week
- Best week flag: Compare current revenue to maximum revenue seen up to and including current row

## Output Requirements

1. **Model Names**: All three models must exist with exact names specified
2. **Materialization**: The mart model must be materialized as TABLE (not view)
3. **Column Order**: Columns must appear in the exact order specified (13 columns total)
4. **Data Types**:
   - week_start must be DATE type (not TIMESTAMP)
   - Monetary values rounded to 2 decimal places
   - Percentages rounded to 2 decimal places
   - growth_status values must be exactly 'Strong Growth', 'Growing', 'Stable', 'Declining', or 'Sharp Decline'
   - is_best_week must be exactly 'Y' or 'N' (not 'Yes'/'No' or booleans)
5. **NULL Handling**:
   - First week: NULL for prev_week_revenue, revenue_change, revenue_growth_pct, growth_status
   - First 3 weeks: NULL for rolling_4wk_avg_revenue
   - Division by zero must produce NULL
6. **Ordering**: Results ordered by week_start ascending
7. **Idempotency**: Multiple dbt runs must produce identical results

## Guidelines
- The SQL syntax should work on both DuckDB and Snowflake (ANSI SQL compatible)
- Use CAST() instead of :: for type casting
- Ensure all window functions have explicit ORDER BY for deterministic results
