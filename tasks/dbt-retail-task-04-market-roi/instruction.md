# Task Instructions: Channel ROI & Payback Model (dbt)

## Goal
Create a marts model that reports monthly marketing ROI and 90-day payback by channel and new-customer segment, plus tests. Do **not** add documentation blocks.

## Files to Create

- DuckDB: `dbt_models_duckdb/models/marts/marketing/rpt_channel_roi_payback_monthly.sql`
- Snowflake: `dbt_models_snowflake/models/marts/marketing/rpt_channel_roi_payback_monthly.sql`
- DuckDB: `dbt_models_duckdb/models/marts/marketing/rpt_channel_roi_payback_monthly.yml`
- Snowflake: `dbt_models_snowflake/models/marts/marketing/rpt_channel_roi_payback_monthly.yml`

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

## Sources (must be `stg_` prefixed)
Use only:
- `stg_fact_marketing_spend` - Contains marketing spend data with channel, date, impressions, clicks, conversions, spend, and revenue fields. Explore the table to understand available columns.
- `stg_analytics__dim_date` - Date dimension with date keys and full dates. Explore to find relevant columns.
- `stg_analytics__fact_sales` - Sales transactions with customer, channel, date, order, and monetary fields. Explore to find relevant columns.
- `stg_analytics__dim_customer` - Customer dimension with segment and tier information. Explore to find relevant columns.
- `stg_analytics__dim_channel` - Channel dimension with channel names and types. Explore to find relevant columns.

## Business Rules & Transform Logic
1. **Monthly grain**
   - Use `date_trunc('month', full_date)` from the date dimension.

2. **Marketing spend aggregation**
   - Group by month + `channel_key`.
   - Sum: impressions, clicks, conversions, spend, revenue attributed.
   - Metrics:
     - CTR = clicks / impressions
     - Conversion rate = conversions / clicks
     - CPA = spend / conversions
     - ROAS = revenue attributed / spend
   - Use `nullif` for all divisions.

3. **Sales facts base**
   - From `stg_analytics__fact_sales`, keep relevant columns including customer_key, channel_key, date_key, order_id, total_amount, profit_amount.

4. **First purchase**
   - First purchase date per customer = minimum `date_key`.
   - First purchase channel = `min(channel_key)` for that date.
   - Join to date dimension to get actual first purchase date.

5. **New customers by segment**
   - Use `stg_analytics__dim_customer` to get segment/tier.
   - If `segment_name` or `tier_name` is null for a new-customer record, use `Unknown`.
   - If a month/channel has **no** new customers, do not synthesize an `Unknown` segment row; leave `segment_name` and `tier_name` as NULL on the base row.
   - Count distinct new customers by month/channel/segment/tier.

6. **Segment mix**
   - Compute total new customers per month/channel.
   - If the total is 0, set `total_new_customers` to NULL (use `nullif`).
   - New-customer share = segment new_customers / total_new_customers; this must be NULL when `total_new_customers` is NULL or 0.

7. **90-day LTV**
   - For each new customer, include sales from first purchase date through day 89.
   - Aggregate 90-day revenue and profit by month/channel/segment/tier.

8. **Monthly sales aggregation**
   - Aggregate by month/channel:
     - sales_revenue, sales_profit, distinct order_count.

9. **Final output columns**
   Include at minimum:
   - month_start, channel_key, channel_name, channel_type
   - segment_name, tier_name
   - impressions, clicks, conversions, ctr, conversion_rate
   - spend_amount, revenue_attributed, roas
   - sales_revenue, sales_profit, order_count
   - order_conversion_rate = order_count / conversions
   - new_customers, total_new_customers, new_customer_share
   - blended_cac = spend / total_new_customers
   - ltv_90d_revenue_per_customer, ltv_90d_profit_per_customer
   - payback_90d_profit_ratio = profit_90d / (spend * new_customer_share)
   - Use `nullif` for all divisions.
   - When there are no new customers for a month/channel, set `new_customers`, `total_new_customers`, `new_customer_share`, `blended_cac`, `ltv_90d_*_per_customer`, and `payback_90d_profit_ratio` to NULL (not 0).

10. **Join strategy**
    - Base: marketing monthly.
    - Left join: channel dimension, sales monthly, segment mix, LTV 90-day.
    - If a base marketing month/channel has no segment mix rows, keep the single base row with `segment_name` and `tier_name` as NULL (do not expand to multiple segments).

## Tests (no documentation text)
Add a YAML file with:
- `version: 2`
- Model: `rpt_channel_roi_payback_monthly`
- Column tests: `not_null` on
  - month_start, channel_key, impressions, clicks, conversions, spend_amount
- Table test: `dbt_utils.unique_combination_of_columns` on
  - month_start, channel_key, segment_name, tier_name

## Run Verification
- `dbt run --select rpt_channel_roi_payback_monthly`
- `dbt test --select rpt_channel_roi_payback_monthly`

## Guidelines

- The SQL syntax should work on both DuckDB and Snowflake (ANSI SQL compatible)
- Use `DATEADD('day', N, date_col)` instead of `date_col + interval 'N day'` for date arithmetic
- Use `NULLIF` for all division operations to avoid division by zero
- **Division precision**: On Snowflake, dividing INTEGER or NUMBER columns truncates decimal precision. Always CAST numerators to FLOAT (e.g., `CAST(clicks AS FLOAT) / NULLIF(impressions, 0)`) to ensure sufficient decimal precision for ratio metrics like CTR and conversion_rate.
