# Cohort Retention Matrix

The Marketing team needs a customer cohort retention analysis to understand how customers from different acquisition channels behave over time.

## Task

Create a dbt model at `models/marts/marketing/cohort_retention_matrix.sql`. Configure it to use schema `marketing_analytics`.

**Note**: The dbt project prefixes custom schemas with `main_`, so `marketing_analytics` becomes `main_marketing_analytics` in the database.

## Files

- DuckDB: `/app/dbt_models_duckdb/models/marts/marketing/cohort_retention_matrix.sql`
- Snowflake: `/app/dbt_models_snowflake/models/marts/marketing/cohort_retention_matrix.sql`

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

## Output Specification

The model must produce exactly these columns:

| Column | Description |
|--------|-------------|
| cohort_month | Signup month in YYYY-MM format |
| acquisition_source | Marketing channel, 'UNKNOWN' for missing values |
| cohort_size | Count of customers who signed up (including those who never ordered) |
| never_ordered_count | Count of customers who never placed any valid order |
| m0_retained | Count of customers who ordered in month 0 (same calendar month as signup) |
| m0_revenue | Total revenue from month 0 orders |
| m0_rate | Percentage of cohort retained in month 0, rounded to 2 decimals (e.g., 45.23) |
| m1_retained | Count of customers who ordered in month 1 |
| m1_revenue | Total revenue from month 1 orders |
| m1_rate | Percentage of cohort retained in month 1, rounded to 2 decimals |
| m1_cumulative | Count of customers who ordered in month 0 OR month 1 (not double-counted) |
| m2_retained | Count of customers who ordered in month 2 |
| m2_revenue | Total revenue from month 2 orders |
| m2_rate | Percentage of cohort retained in month 2, rounded to 2 decimals |
| m2_cumulative | Count of customers who ordered in month 0, 1, OR 2 (not double-counted) |
| m3_retained | Count of customers who ordered in month 3 |
| m3_revenue | Total revenue from month 3 orders |
| m3_rate | Percentage of cohort retained in month 3, rounded to 2 decimals |
| m3_cumulative | Count of customers who ordered in months 0-3 (not double-counted) |
| m6_retained | Count of customers who ordered in month 6 |
| m6_revenue | Total revenue from month 6 orders |
| m6_rate | Percentage of cohort retained in month 6, rounded to 2 decimals |
| m6_cumulative | Count of customers who ordered in months 0-6 (not double-counted) |
| m12_retained | Count of customers who ordered in month 12 |
| m12_revenue | Total revenue from month 12 orders |
| m12_rate | Percentage of cohort retained in month 12, rounded to 2 decimals |
| m12_cumulative | Count of customers who ordered in months 0-12 (not double-counted) |
| early_churned_count | Count of customers who ordered in month 0 but never ordered again after month 0 |
| cohort_ltv | Total lifetime revenue divided by cohort_size, rounded to 2 decimals |
| avg_days_to_second_purchase | Average days between 1st and 2nd order for customers with 2+ orders, NULL if none in cohort |

## Business Rules

1. **Cohort definition**: Group customers by their account creation month (from CUSTOMER.CUSTOMERS). This is NOT based on first order date.

2. **Cohort size**: Includes ALL customers who signed up in that month, even if they never placed an order.

3. **Month calculation**: Month N means exactly N calendar months after the signup month. A customer who signed up January 15th and ordered February 3rd counts as month 1 (not month 0).

4. **Valid orders**: Only count orders with STATUS = 'COMPLETED'. Exclude orders where TEST_ORDER_FLAG, SAMPLE_ORDER_FLAG, or INTERNAL_ORDER_FLAG is true.

5. **Channel filtering**: Exclude any acquisition_source that has fewer than 10 total customers across all cohorts.

6. **Revenue column**: Use GRAND_TOTAL from the orders table. Default to 0 when no orders exist.

7. **Retained count**: Count distinct customers with at least one valid order in that specific month offset.

8. **Retention rate**: Calculate as (retained_count / cohort_size) * 100, rounded to 2 decimal places. Return 0.00 if cohort_size is 0.

9. **Cumulative retention**: Count distinct customers who ordered in ANY month from 0 up to and including that month. A customer ordering in multiple months counts once.

10. **Never ordered**: Count customers in the cohort who have zero valid orders ever.

11. **Early churned**: Count customers who placed at least one order in month 0 but have no orders in any month after month 0.

12. **Sorting**: Order by cohort_month ascending, then acquisition_source ascending.

## Data Sources

- Customer data: CUSTOMER.CUSTOMERS table (contains customer signup dates and acquisition source)
- Order data: ORDERS.ORDERS table (contains order details and flags)

Find the appropriate dbt source references by examining the existing source definitions in the project.

## Guidelines

- The SQL syntax should work on both DuckDB and Snowflake (ANSI SQL compatible)
