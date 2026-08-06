### Task: Customer Churn Early Warning

You're an analytics engineer building a **weekly churn early-warning** mart. The warehouse already contains a reference dbt project with pre-built models.

Create a dbt project at `/app/dbt_project` and implement:
- `models/marts/customer/rpt_customer_churn_early_warning_fixed.sql`

## Database Backend

This task supports both DuckDB and Snowflake. **Run `echo $DB_TYPE` in a shell BEFORE you write any code or spawn any subagents — the live env determines which backend the verifier runs against.** Do NOT assume a default from this prose. Both `/app/dbt_models_duckdb/` and `/app/dbt_models_snowflake/` exist on disk; the verifier only checks the project matching the live `$DB_TYPE`.

### DuckDB
- Set `DB_TYPE=duckdb`
- Database path: `$DUCKDB_PATH` (default: `/app/database/retail.duckdb`)
- Reference dbt project: `/app/dbt_models_duckdb`

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
- Reference dbt project: `/app/dbt_models_snowflake`

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

## Source Data

Source orders from `main.int_sales__orders_enriched`:
- Build it first from the reference dbt project. Explore the table to understand available columns.
- Key columns include: `customer_id`, `order_id`, `ordered_at`, `grand_total`

## Output table

Materialize `analytics.rpt_customer_churn_early_warning_fixed` with columns:
- `customer_id` (STRING)
- `week_start` (DATE) -- Monday-based week; use the latest full week in the data.
- `first_order_date` (DATE)
- `last_order_date` (DATE)
- `days_since_last_order` (INTEGER)
- `order_count_90d` (INTEGER) -- number of orders in the last 90 days as of `week_start`
- `lifetime_orders` (INTEGER)
- `lifetime_revenue` (NUMERIC(18,2))
- `churn_risk_tier` (STRING; one of `low`, `medium`, `high`)

## Business rules

- Use a deterministic **as-of week**:
  - `as_of_date` = MAX(ordered_at) from `int_sales__orders_enriched`
  - `week_start` = DATE_TRUNC('week', as_of_date)::DATE
- For each `customer_id`:
  - `first_order_date` = MIN(ordered_at)::DATE
  - `last_order_date`  = MAX(ordered_at)::DATE
  - `days_since_last_order` = DATEDIFF('day', last_order_date, as_of_date)
  - `order_count_90d` = count of distinct `order_id` where `ordered_at` >= as_of_date - 90 days
  - `lifetime_orders` = count of distinct `order_id`
  - `lifetime_revenue` = SUM(grand_total) cast to NUMERIC(18,2)
- Churn risk tiers:
  - `low`    if `days_since_last_order <= 30`
  - `medium` if `31 <= days_since_last_order <= 90`
  - `high`   if `days_since_last_order > 90`

## Quality requirements

- No NULL `customer_id`.
- No negative `lifetime_revenue`.
- `churn_risk_tier` must be in (`low`, `medium`, `high`) and consistent with `days_since_last_order`.
- Reconciliation: total `lifetime_orders` and `lifetime_revenue` across the mart should match the source aggregates within 0.01 and 1-row tolerance.

## Guidelines

- Profile name must be `retail_dw_master`.
- Your dbt profile should write to schema `analytics`.
- Ensure idempotent execution (multiple runs produce same results).
- Use explicit type casts where needed.
- Handle NULL values appropriately.
