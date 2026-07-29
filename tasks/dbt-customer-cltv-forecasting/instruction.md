### Task: Customer CLTV Forecasting (dbt)

Build a dbt project at `/app/dbt_project` that produces a customer lifetime value (CLTV) forecast table in schema `analytics` using orders from `main.int_sales__orders_enriched` (materialized by the reference project).

#### Source

Use `main.int_sales__orders_enriched` and the following columns (ignore extras if present):
- `order_id`
- `customer_id` (string, nullable)
- `ordered_at` (timestamp)
- `grand_total` (numeric)
- `is_cancelled` (boolean)

#### Required Output

Create **one** table:

**`analytics.rpt_customer_cltv_forecast`**

Grain: one row per `customer_id`.

Columns:
- `customer_id` (VARCHAR): Customer identifier
- `as_of_date` (DATE): Maximum order date from source data
- `current_lifetime_revenue` (DECIMAL(18,2)): Sum of `grand_total` for all non-cancelled orders up to `as_of_date`
- `current_order_count` (INTEGER): Count of distinct `order_id` for non-cancelled orders
- `avg_order_value` (DECIMAL(18,2)): `current_lifetime_revenue / GREATEST(current_order_count, 1)`
- `days_since_last_order` (INTEGER): Days between last order date and `as_of_date` (NULL if no orders)
- `forecast_3m_revenue` (DECIMAL(18,2)): Projected revenue for next 3 months
- `forecast_6m_revenue` (DECIMAL(18,2)): Projected revenue for next 6 months
- `forecast_12m_revenue` (DECIMAL(18,2)): Projected revenue for next 12 months

#### Rules

- Exclude rows where `is_cancelled = true`.
- Exclude rows where `customer_id IS NULL`.
- `as_of_date` must be the same for all rows: `MAX(CAST(ordered_at AS DATE))` from source.
- Calculate average monthly revenue over the last 6 full months before `as_of_date`:
  - `avg_monthly_revenue = SUM(monthly_revenue) / COUNT(DISTINCT months)` where months are in the 6-month window
  - If no orders in last 6 months, set `avg_monthly_revenue = 0`
- Forecast calculations:
  - `forecast_3m_revenue = current_lifetime_revenue + 3 * avg_monthly_revenue`
  - `forecast_6m_revenue = current_lifetime_revenue + 6 * avg_monthly_revenue`
  - `forecast_12m_revenue = current_lifetime_revenue + 12 * avg_monthly_revenue`
- All revenue and forecast fields must be non-negative.
- `forecast_3m_revenue <= forecast_6m_revenue <= forecast_12m_revenue` (monotonicity).

#### Quality Requirements

- No NULL `customer_id`.
- All revenue and forecast fields must be non-negative.
- Forecasts must be non-decreasing: `forecast_3m_revenue <= forecast_6m_revenue <= forecast_12m_revenue`.
- Reconciliation: Sum of `current_lifetime_revenue` must match total revenue from source (where `is_cancelled = false`) within 0.01 tolerance.

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
- Create a `profiles.yml` in the dbt project directory with profile name matching your `dbt_project.yml`
- Set `DBT_PROFILES_DIR` environment variable to the directory containing `profiles.yml`

### DuckDB Profile
Configure with `type: duckdb` and the database path from `$DUCKDB_PATH`.

### Snowflake Profile
Configure with `type: snowflake` using password authentication:
- Use the environment variables for account, user, password, database, schema, warehouse, and role
- Set the profile's `schema:` to `$SNOWFLAKE_SCHEMA` — do NOT leave it blank. A blank or omitted schema makes Snowflake silently default to `PUBLIC`, so your models get built in the wrong schema and the verifier cannot find them.

## Files

- Reference dbt project (DuckDB): `/app/dbt_transforms`
- Reference dbt project (Snowflake): `/app/dbt_models_snowflake`
- Your dbt project: `/app/dbt_project` (you create this)

## Guidelines

- The SQL syntax should work on both DuckDB and Snowflake (ANSI SQL compatible)
- Use CAST() instead of :: for type casting
- Use DATEDIFF function for date differences (compatible with both)
