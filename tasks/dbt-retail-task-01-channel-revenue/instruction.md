## Goal
Create a dbt model that outputs monthly `revenue`,`profit`,`discount_amount`,`margin_rate`,`avg_order_value`,`discount_rate` by channel. The result should support channel mix and budget optimization analysis.

## Database Backend

This task supports both DuckDB and Snowflake. **Run `echo $DB_TYPE` in a shell BEFORE you write any code or spawn any subagents — the live env determines which backend the verifier runs against.** Do NOT assume a default from this prose. Both `/app/dbt_models_duckdb/` and `/app/dbt_models_snowflake/` exist on disk; the verifier only checks the project matching the live `$DB_TYPE`.

### DuckDB
- Set `DB_TYPE=duckdb`
- Database path: `$DUCKDB_PATH` (default: `/app/database/retail.duckdb`)
- Model location: `/app/dbt_models_duckdb/models/marts/time_series/sales/ts_sales__channel_revenue_margin_monthly.sql`

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
- Model location: `/app/dbt_models_snowflake/models/marts/time_series/sales/ts_sales__channel_revenue_margin_monthly.sql`

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

## Suggested source files (read if helpful to align fields and keys)
- `stg_analytics__dim_date.sql`
- `dim_dim_channel.sql`
- `dim_fact_sales.sql`
- `stg_fact_sales.sql`

## What to build
- Add a new model under `models/marts/time_series/sales/` in the appropriate dbt project directory that produces a monthly trend by channel.
- Include channel identifiers/attributes and month fields, plus the required metrics.
- Materialize as a view and tag with `time_series`, `sales`, `monthly`, `channel` (required tags).
- Suggested model name: `ts_sales__channel_revenue_margin_monthly`.

## Required output schema (at minimum)
- `month_start`
- `sales_year`
- `sales_month`
- `channel_key`
- `channel_id`
- `channel_code`
- `channel_name`
- `channel_type`
- `order_count`
- `revenue`
- `profit`
- `discount_amount`
- `margin_rate`
- `avg_order_value`
- `discount_rate`
- `dbt_updated_at`

## How to assemble the data
- Use only `dim_dim_channel` for channel attributes; do not use `stg_dim_channel`.
- Use the sales fact dimension (`dim_fact_sales`) for keys (including date and channel) and order identifiers when available.
- Use `stg_fact_sales` for monetary metrics (total, profit, discount) and join it to `dim_fact_sales` on the sales identifier.
- Use the date dimension (`stg_analytics__dim_date`) for month/year fields and derive `month_start` via `date_trunc('month', full_date)`.
- Cast `channel_key` to text before joining to `dim_dim_channel`.

## Metric definitions
- Revenue: sum of total sales amount.
- Profit: sum of profit amount.
- AOV: revenue divided by distinct order count.
- Discount rate: discount amount divided by total amount plus discount amount.
- Margin rate: profit divided by revenue.

## Grain and aggregation
- Aggregate to monthly grain by channel (one row per channel per month).
- Aggregate using the date from the date dimension and channel from the channel dimension.
- Include distinct order counts to support AOV.

## Output expectations
- If you run dbt, prefer running only this model with `dbt run`.
- Ensure that the final report contains `month_start`,`sales_year`,`sales_month`
- Expose channel information that is required

## Guidelines
- Use `nullif()` for safe division
- Use `date_trunc('month', ...)` for month grouping
- Use `current_timestamp` for `dbt_updated_at`
- Use `cast(channel_key as text)` for channel key joins

Notes: Ignore warnings.
