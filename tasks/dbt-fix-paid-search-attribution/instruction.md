### Task: Fix Paid Search Attribution Report

You're an analytics engineer who needs to rebuild the paid search attribution mart. The data warehouse already contains a GA4-style sessions/events dataset and a reference dbt project (`/app/dbt_transforms`). Your job is to create a new dbt model `rpt_paid_search_attribution_fixed.sql` inside a dbt project that produces a clean daily paid search attribution table. For DuckDB, create the project at `/app/dbt_models_duckdb`; for Snowflake, at `/app/dbt_models_snowflake`. Check `DB_TYPE` to determine which backend to use.

#### Goal
Materialize a table `analytics.rpt_paid_search_attribution_fixed` with the following columns:
1) `attribution_date` (DATE)
2) `channel` (STRING)
3) `medium` (STRING)
4) `campaign` (STRING)
5) `sessions` (INTEGER)
6) `conversions` (INTEGER)
7) `attributed_revenue` (NUMERIC with 2 decimals)
8) `conversion_rate` (NUMERIC between 0 and 1 with 4 decimals)

#### Business rules
- Use GA session data from the database.
- Limit to the last 90 days of data relative to the most recent session start date in the dataset (i.e., use a subquery like `CAST(session_start AS DATE) >= (SELECT MAX(CAST(session_start AS DATE)) FROM <sessions_source>) - INTERVAL '90 days'` rather than CURRENT_DATE).
- Treat missing `utm_source` as `direct`, missing `utm_medium` and `utm_campaign` as `none`.
- Count sessions by distinct `session_id`.
- `conversions`: count sessions where `is_converted = true`.
- `attributed_revenue`: sum purchase revenue from events joined to converted sessions. Prefer `int_sessions_events_joined` if available; otherwise fall back to `stg_ga__events` and `event_value`.
- `conversion_rate`: conversions / sessions (rounded to 4 decimals), 0 when no sessions.
- Focus on paid search quality: your output may include multiple channels, but paid search (e.g., google / cpc) should not be lost or double-counted.

#### Database Backend
This task supports two database backends:

- **DuckDB**: Local DuckDB database at `/app/database/retail.duckdb`. The dbt project is at `/app/dbt_models_duckdb` (or the path in `DBT_PROJECT_DIR_DUCKDB`).
- **Snowflake**: Cloud Snowflake database. Connection details are provided via environment variables (`SNOWFLAKE_ACCOUNT`, `SNOWFLAKE_USER`, `SNOWFLAKE_PASSWORD`, `SNOWFLAKE_DATABASE`, `SNOWFLAKE_SCHEMA`, `SNOWFLAKE_WAREHOUSE`, `SNOWFLAKE_ROLE`). The dbt project is at `/app/dbt_models_snowflake` (or the path in `DBT_PROJECT_DIR_SNOWFLAKE`).

Check the `DB_TYPE` environment variable to determine which backend is active.

#### dbt Profile Setup

Create a `profiles.yml` for the dbt project:

- For DuckDB: Configure with `type: duckdb` and `path` pointing to the database file. Profile name: `retail_dw_master`.
- For Snowflake: Configure with `type: snowflake` and use the environment variables for connection settings (password authentication). Profile name: `retail_dw_master`.

#### Environment
- Base image already includes dbt, DuckDB/Snowflake connectors, and the reference project at `/app/dbt_transforms`.
- For DuckDB: Database file at `/app/database/retail.duckdb`.
- For Snowflake: Connection via environment variables.
- You should create your own dbt project under the appropriate directory (see Database Backend section above) with schema `analytics`.

#### Schema Configuration (IMPORTANT)
By default, dbt concatenates the profile's default schema with any custom schema (e.g., producing `main_analytics` instead of `analytics`). You **must** override the `generate_schema_name` macro so that your model materializes in exactly the `analytics` schema. Create the file `macros/utils/generate_schema_name.sql` (overwriting any existing one) with:

```sql
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- if custom_schema_name is not none -%}
        {{ custom_schema_name | trim }}
    {%- else -%}
        {{ default_schema }}
    {%- endif -%}
{%- endmacro %}
```

This ensures the model lands in `analytics` rather than `main_analytics`.

#### What the tests expect
- A dbt project at the appropriate directory (`/app/dbt_models_duckdb` for DuckDB, `/app/dbt_models_snowflake` for Snowflake) with model `models/marts/marketing/rpt_paid_search_attribution_fixed.sql`.
- Running `dbt run --select rpt_paid_search_attribution_fixed` succeeds and creates `analytics.rpt_paid_search_attribution_fixed`.
- Columns and data quality match the business rules above.

#### Tips
- Reuse the reference models by running `dbt run --select stg_ga__sessions stg_ga__events int_sessions_events_joined` inside `/app/dbt_transforms` to ensure sources are built.
- In your model, prefer relations from the `main` schema (that's where the reference models materialize).
- Use `adapter.get_relation` and `adapter.get_columns_in_relation` to detect available relations/columns, just like a robust dbt macro would.
- Round revenue to 2 decimals and conversion rate to 4 decimals to avoid precision issues.
