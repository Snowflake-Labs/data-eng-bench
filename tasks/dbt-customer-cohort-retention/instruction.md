# Customer Cohort Retention Analysis

Build dbt models for customer cohort retention analysis.

## Database Backend

This task supports both DuckDB and Snowflake. **Run `echo $DB_TYPE` in a shell BEFORE you write any code or spawn any subagents — the live env determines which backend the verifier runs against.** Do NOT assume a default from this prose. Both `/app/dbt_models_duckdb/` and `/app/dbt_models_snowflake/` exist on disk; the verifier only checks the project matching the live `$DB_TYPE`.

### DuckDB
- Set `DB_TYPE=duckdb`
- Database path: `$DUCKDB_PATH` (default: `/app/database/retail.duckdb`)
- dbt Project: `/app/dbt_models_duckdb`

### Snowflake
- Set `DB_TYPE=snowflake`
- dbt Project: `/app/dbt_models_snowflake`
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

## Source Data

Explore the raw tables in the `main` schema to understand available data:
- `main.orders` - Order transactions
- `main.customers` - Customer information

## Data Filtering

- Only include orders from years 2023 and 2024
- Only include orders that were successfully completed (exclude cancelled and returned orders)

## Cohort Definition

- A customer's cohort is determined by the month of their first valid order
- Track customer behavior month-by-month relative to when they joined

## Required Output

Create dbt models that produce tables `cohort_retention`, `cohort_revenue`, and `cohort_summary` in the `main` schema.

Run `dbt deps` before `dbt run`.

### `main.cohort_retention`

Monthly retention tracking for each cohort:

| Column | Type | Description |
|--------|------|-------------|
| `cohort_month` | VARCHAR | Format: `YYYY-MM` (e.g., `2023-01`) |
| `months_since_first_order` | INTEGER | 0, 1, 2, ... |
| `cohort_size` | INTEGER | Total customers in this cohort |
| `retained_customers` | INTEGER | Customers who purchased in this specific month |
| `retention_rate` | DECIMAL(5,2) | Percentage of cohort retained this month (0-100 scale) |
| `cumulative_retained` | INTEGER | Running distinct count of customers who have placed at least one order in ANY month from month 0 up to and including this month. Each customer is counted at most once regardless of how many months they were active. This value must be non-decreasing within a cohort. |
| `cumulative_retention_rate` | DECIMAL(5,2) | Cumulative retention as a percentage (0-100 scale): `cumulative_retained / cohort_size * 100` |

**Example**: Suppose cohort `2023-01` has `cohort_size = 14`. All 14 customers are active in month 0, so `retained_customers = 14` and `cumulative_retained = 14`. In month 1, 5 customers place orders (3 of whom were also active in month 0, plus 2 who were not active in month 0 -- but note all 14 were active in month 0, so the 5 in month 1 are a subset). Here `retained_customers = 5`, and `cumulative_retained = 14` (since the set of distinct customers active in months 0 through 1 is still the same 14). If in month 2, 3 customers are active and 1 of them was NOT active in months 0 or 1 (impossible in this example since all 14 were active in month 0, but in general), then `cumulative_retained` would increase by 1. The key point: `cumulative_retained` is NOT a running sum of `retained_customers`. It is the count of the distinct union of customers active in any month from 0 through M.

### `main.cohort_revenue`

Revenue analysis by cohort and month:

| Column | Type | Description |
|--------|------|-------------|
| `cohort_month` | VARCHAR | Format: `YYYY-MM` (e.g., `2023-01`) |
| `months_since_first_order` | INTEGER | 0, 1, 2, ... |
| `cohort_size` | INTEGER | Total customers in this cohort |
| `total_revenue` | DECIMAL | Revenue generated this month |
| `revenue_per_customer` | DECIMAL | Average revenue per cohort member this month |
| `cumulative_revenue` | DECIMAL | Running total of revenue from month 0 through this month |
| `cumulative_revenue_per_customer` | DECIMAL | Cumulative revenue averaged across cohort |

### `main.cohort_summary`

One row per cohort with lifetime aggregate metrics:

| Column | Type | Description |
|--------|------|-------------|
| `cohort_month` | VARCHAR | Format: `YYYY-MM` |
| `cohort_size` | INTEGER | Number of customers in the cohort |
| `total_lifetime_revenue` | DECIMAL | Total revenue from this cohort |
| `avg_revenue_per_customer` | DECIMAL | Lifetime revenue per customer |
| `avg_orders_per_customer` | DECIMAL | Average orders per customer |
| `months_active` | INTEGER | Distinct months with at least one purchase from this cohort |
| `retention_month_6` | DECIMAL(5,2) | Retention rate at 6 months (NULL if insufficient data) |
| `retention_month_12` | DECIMAL(5,2) | Retention rate at 12 months (NULL if insufficient data) |

## Notes

- Round decimal values to 2 decimal places
- Retention rates should be on a 0-100 percentage scale
- `cohort_size` must be consistent for the same cohort across all tables
- For date formatting functions that differ between backends, use Jinja conditionals:
  - DuckDB: `strftime('%Y-%m', date_col)`
  - Snowflake: `TO_CHAR(date_col, 'YYYY-MM')`

## Guidelines

- Use `{% if target.type == 'duckdb' %}...{% else %}...{% endif %}` for backend-specific SQL
