# Deferred Revenue Recognition Schedule

The Finance team needs a revenue recognition schedule for audit purposes. They need to see how deferred revenue is recognized over time and compare calculated amounts to what was actually posted.

## Task

Create a dbt model at `models/marts/finance/deferred_revenue_schedule.sql`. Configure it to use schema `finance_analytics`.

**Note**: The dbt project prefixes custom schemas with `main_`, so `finance_analytics` becomes `main_finance_analytics` in the database.

## Files

- DuckDB: `/app/dbt_models_duckdb/models/marts/finance/deferred_revenue_schedule.sql`
- Snowflake: `/app/dbt_models_snowflake/models/marts/finance/deferred_revenue_schedule.sql`

Run `dbt deps` before running models.

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

## Background

Deferred revenue entries have a recognition window (start and end dates). Revenue must be recognized over this period according to accounting rules:

- **Short recognition periods** (< 60 days): Recognize the full amount immediately in the first month
- **Longer periods** (>= 60 days): Spread recognition evenly across all months based on the number of days in each month that fall within the recognition window

## Output Specification

The output should have **one row per deferred entry per calendar month** that overlaps with the recognition window. For example, an entry spanning Jan 15 to Apr 10 would have 4 rows (one each for January, February, March, April).

The model must produce exactly these columns:

| Column | Description |
|--------|-------------|
| deferred_id | Identifier for the deferred revenue entry |
| order_id | Associated order |
| order_type | Type of order (from orders table) |
| total_deferred_amount | Original deferred amount |
| period_name | Calendar month (YYYY-MM format) |
| period_start_date | First day of the calendar month |
| period_end_date | Last day of the calendar month |
| recognition_start | When recognition begins |
| recognition_end | When recognition ends |
| days_in_period | How many days of this entry fall within this calendar month |
| total_recognition_days | Total days in the recognition window |
| calculated_recognition_amount | Prorated amount for this period (2 decimal places) |
| posted_recognition_amount | What was actually posted for this order/month (0 if nothing) |
| recognition_variance | Difference between calculated and posted |
| recognition_method | Either 'STRAIGHT_LINE' or 'IMMEDIATE' based on the 60-day threshold |
| cumulative_recognized | Running total of recognition through this period |
| deferred_remaining | What's left to recognize after this period |

## Business Rules

1. Only include entries that have both recognition start and end dates
2. Generate calendar months dynamically based on the data - don't assume fixed date ranges
3. For straight-line recognition, prorate based on actual days (not a flat monthly amount)
4. For immediate recognition, the full amount goes to the first period; subsequent periods show 0
5. The recognition amounts across all periods should sum to the total deferred amount
6. The days across all periods should sum to the total recognition days
7. Compare to posted amounts from the revenue recognition table to identify variances
8. Sort by deferred entry, then chronologically by period

## Data Sources

- Deferred revenue entries with recognition windows
- Posted revenue recognition amounts to compare against
- Order details for order type

Find the appropriate dbt source references by examining the existing source definitions in the project.
