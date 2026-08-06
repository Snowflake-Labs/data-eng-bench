# RFM Customer Segmentation

Build a dbt project that implements RFM (Recency, Frequency, Monetary) customer segmentation using the enterprise retail data warehouse.

## Database Backend

This task supports both DuckDB and Snowflake. **Run `echo $DB_TYPE` in a shell BEFORE you write any code or spawn any subagents — the live env determines which backend the verifier runs against.** Do NOT assume a default from this prose. Reference dbt projects exist at `/app/dbt_models_duckdb/` and `/app/dbt_models_snowflake/` for inspection only. Write your dbt project at `/app/dbt_project` — outputs in the reference directories are not graded.

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
- Create a `profiles.yml` in the dbt project directory with profile name `dbt_project`
- Set `DBT_PROFILES_DIR` environment variable to the directory containing `profiles.yml`

### DuckDB Profile
Configure with `type: duckdb` and the database path from `$DUCKDB_PATH`.

### Snowflake Profile
Configure with `type: snowflake` using password authentication:
- Use the environment variables for account, user, password, database, schema, warehouse, and role

## Data Environment

- **Analysis date**: Use `2024-12-01` as the reference date for recency calculations
- **Analysis period**: Orders from `2023-01-01` to `2024-11-30` (23 months)

## Project Setup

- **Project location**: `/app/dbt_project`
- **Schema**: `rfm_analytics`

**Configuration Note**: Set the schema only in `profiles.yml`. Do not add `+schema` in `dbt_project.yml` (dbt concatenates them, causing schema name issues).

## Source Data

Reference the raw tables in the database:

1. **Raw orders table** in schema `main`: `main.orders`
   - Columns include `order_id`, `customer_id`, `ordered_at`, `grand_total`, `status`

2. **Raw customers table** in schema `main`: `main.customers`
   - Columns include `customer_id`, `customer_number`, `first_name`, `last_name`, `status`

Create sources that point to these raw tables in the `main` schema, and build the following staging models (use these exact names):
- `stg_orders__orders`
- `stg_customer__customers`

## Required Models

### Staging (`models/staging/`)

Create source definitions to access the existing tables in the database.

### Intermediate (`models/intermediate/`)

**int_rfm_metrics.sql** - Calculate RFM metrics per customer:
- Only include orders with `status` NOT IN ('CANCELLED', 'RETURNED', 'FAILED')
- Only include customers with at least 1 valid order in the analysis period
- Calculate:
  - `recency_days`: Days between analysis date (2024-12-01) and customer's most recent order
  - `frequency`: Count of orders in the analysis period
  - `monetary`: Total `grand_total` in the analysis period

### Marts (`models/marts/`)

**rfm_scores.sql** - Assign RFM scores using NTILE:
- Use `NTILE(5)` to assign scores 1-5 for each dimension
- **Recency**: Score 5 = most recent (lowest days), Score 1 = least recent (highest days)
- **Frequency**: Score 5 = most frequent, Score 1 = least frequent
- **Monetary**: Score 5 = highest spend, Score 1 = lowest spend
- Add a deterministic secondary sort key (e.g., `customer_id`) in all NTILE windows to ensure reproducible tie-breaking.

**rfm_segments.sql** - Final segmentation model with columns:
- `customer_id`
- `customer_name` (concatenate first_name and last_name from customers)
- `recency_days`
- `frequency`
- `monetary`
- `r_score` (1-5)
- `f_score` (1-5)
- `m_score` (1-5)
- `rfm_score` (concatenated string like "555", "321", etc.)
- `rfm_segment` - Assign segment based on RFM score combination:
  - **Champions**: r_score >= 4 AND f_score >= 4 AND m_score >= 4
  - **Loyal Customers**: f_score >= 4 AND m_score >= 3
  - **Potential Loyalists**: r_score >= 4 AND f_score >= 2 AND f_score <= 4
  - **Recent Customers**: r_score >= 4 AND f_score = 1
  - **Promising**: r_score >= 3 AND f_score <= 2 AND m_score >= 2
  - **Need Attention**: r_score >= 2 AND r_score <= 3 AND f_score >= 2 AND f_score <= 3
  - **About to Sleep**: r_score = 2 AND f_score <= 2
  - **At Risk**: r_score <= 2 AND f_score >= 3 AND m_score >= 3
  - **Cannot Lose**: r_score <= 2 AND f_score >= 4 AND m_score >= 4
  - **Hibernating**: r_score <= 2 AND f_score <= 2 AND m_score <= 2
  - **Lost**: r_score = 1 AND f_score = 1
  - **Other**: All remaining combinations

## Output Requirements

The `rfm_segments` model must:
1. Include all customers with valid orders in the analysis period
2. Have no NULL values in any column
3. Have exactly one row per customer
4. Have valid scores (1-5) for r_score, f_score, m_score
5. Have a valid segment assignment for every customer

## Segment Priority Rules

When multiple segment conditions match, use this priority order (first match wins):
1. Champions
2. Cannot Lose
3. Loyal Customers
4. At Risk
5. Potential Loyalists
6. Recent Customers
7. Promising
8. Need Attention
9. About to Sleep
10. Hibernating
11. Lost
12. Other

## Guidelines

- Handle ties in NTILE appropriately (use deterministic sorting)
- Round monetary values to 2 decimal places
- Ensure idempotent execution (multiple runs should produce same results)
- Install any additional libraries as needed
