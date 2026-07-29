### Task: Fix CAC Payback Waterfall

You're an analytics engineer rebuilding a **CAC payback waterfall** report. The warehouse already contains a reference dbt project at `/app/dbt_transforms` with various models materialized. Marketing spend data exists in the warehouse -- find the right source table by exploring available models.

Create a dbt project at `/app/dbt_project` and implement:
- `models/marts/marketing/rpt_cac_payback_waterfall_fixed.sql`

## Database Backend

This task supports two database backends:

- **DuckDB**: Local DuckDB database at `/app/database/retail.duckdb`. The dbt project is at `/app/dbt_models_duckdb/`.
- **Snowflake**: Cloud Snowflake database. Connection details are provided via environment variables (`SNOWFLAKE_ACCOUNT`, `SNOWFLAKE_USER`, `SNOWFLAKE_PASSWORD`, `SNOWFLAKE_DATABASE`, `SNOWFLAKE_SCHEMA`, `SNOWFLAKE_WAREHOUSE`, `SNOWFLAKE_ROLE`). The dbt project is at `/app/dbt_models_snowflake/`.

Check the `DB_TYPE` environment variable to determine which backend is active.

## dbt Profile Setup

Create a `profiles.yml` with profile name `retail_dw_master`:

- For DuckDB: Configure with `type: duckdb` and `path` pointing to the database file.
- For Snowflake: Configure with `type: snowflake` and use the environment variables for connection settings (password authentication). Set the profile's `schema:` to `$SNOWFLAKE_SCHEMA` — do NOT leave it blank (a blank schema makes Snowflake default to `PUBLIC`, so models land in the wrong schema and the verifier cannot find them).

#### Output table
Materialize `analytics.rpt_cac_payback_waterfall_fixed` with columns:
- `campaign_id` (STRING)
- `channel_key` (INTEGER)
- `cohort_date` (DATE) -- the first date we observe spend for the campaign
- `days_since_cohort` (INTEGER) -- 0 for the cohort date
- `daily_spend` (NUMERIC(12,2))
- `daily_revenue_attributed` (NUMERIC(12,2))
- `cumulative_spend` (NUMERIC(12,2))
- `cumulative_revenue` (NUMERIC(12,2))
- `payback_ratio` (NUMERIC(10,4)) -- compute a payback ratio showing how much of the investment has been recouped
- `is_paid_back` (BOOLEAN) -- true when the campaign has recouped its investment

#### Business rules
- Explore the source to understand what fields are available. You will need to find marketing spend data among the models materialized in the warehouse.
- Build the waterfall per **campaign_id** (grain: one row per `campaign_id` + `days_since_cohort`).
- **Channel key handling**: Each campaign must have exactly one `channel_key` in the output. If the source data has a campaign appearing across multiple `channel_key` values, pick the `channel_key` with the highest total `spend_amount` for that campaign. Aggregate all spend and revenue across channel keys into a single campaign row before building the waterfall.
- Include all campaign-days in the data and compute daily and cumulative values.
- Round currency fields to 2 decimals and payback_ratio to 4 decimals.

#### Quality requirements
- No negative spends or revenue.
- `cumulative_spend` and `cumulative_revenue` must be non-decreasing within each campaign.
- Reconciliation: for each campaign, the last row's cumulative totals must equal total source values within 0.01.

#### SQL Compatibility Guidelines
- Use Jinja conditionals (`{% if target.type == 'snowflake' %}`) for database-specific syntax
- DuckDB and Snowflake have different date/type functions -- handle both
- The SQL should work on both DuckDB and Snowflake

#### Environment notes
- Base image includes dbt + DuckDB + `/app/dbt_transforms`.
- Your dbt profile should write to schema `analytics`.
