# Daily Cohorts Reporting

Build a dbt model called `rpt_daily_cohorts` that analyzes customer retention by grouping customers into cohorts based on when they first placed an order.

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

## Requirements

Create a report in `models/marts/analytics/rpt_daily_cohorts.sql`:

- DuckDB: `/app/dbt_models_duckdb/models/marts/analytics/rpt_daily_cohorts.sql`
- Snowflake: `/app/dbt_models_snowflake/models/marts/analytics/rpt_daily_cohorts.sql`

The model should produce a daily cohort retention analysis with the following output columns:

- `cohort_date`
- `cohort_size`
- `day_0_customers`
- `day_7_customers`
- `day_30_customers`
- `day_90_customers`
- `day_0_retention`
- `day_7_retention`
- `day_30_retention`
- `day_90_retention`

The `day_N_customers` columns use cumulative semantics: each represents the count of customers who made a purchase within N days of the cohort_date (inclusive). For example, `day_7_customers` counts all customers with at least one order within 7 days of their cohort_date, which always includes all day_0 customers. As a result, `day_7_customers >= day_0_customers` and so on.

Explore the available staging models and their schemas to identify the relevant source data and columns.

## Data Sources

The dbt project already has staging models defined. Investigate the existing models in the project to find the appropriate orders data source. You will need to understand which columns are available and how to use them for the cohort analysis.

## Implementation Notes

- The model should be materialized as a table
- Ensure your SQL is compatible with both DuckDB and Snowflake (ANSI SQL)
- Think carefully about data types and edge cases in your calculations

## Success Criteria

1. The model compiles and runs without errors
2. Retention metrics are logically consistent
3. Each cohort date appears exactly once in the output
4. The total number of customers across all cohorts accounts for all customers in the source data
