# Customer Churn Cohort Analysis with Retention Curves

Build a dbt project that performs cohort analysis, calculates customer retention curves, and computes customer lifetime value (CLV) metrics with churn probability scoring.

## Environment

- **DuckDB database**: `/app/database/retail.duckdb`
- **DuckDB dbt project**: `/app/dbt_models_duckdb`
- **Snowflake dbt project**: `/app/dbt_models_snowflake`

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

## Data

You can expect these input schemas to be available in the database:
 - `ANALYTICS.FACT_SALES`: Sales transactions
   - Columns: `SALE_KEY`, `DATE_KEY`, `CUSTOMER_KEY`, `TOTAL_AMOUNT`, `ORDER_ID`, `ORDER_LINE_ID`
 - `ANALYTICS.DIM_CUSTOMER`: Customer dimension for linking keys
   - Columns: `CUSTOMER_KEY`, `CUSTOMER_ID`, `SEGMENT_NAME`, `CITY`, `STATE`, `COUNTRY`
 - `ANALYTICS.DIM_DATE`: Date dimension
   - Columns: `DATE_KEY`, `FULL_DATE`, `YEAR`, `MONTH_NUMBER`, `DAY_OF_MONTH`
 - `CUSTOMER.CUSTOMERS`: Detailed customer demographics
   - Columns: `CUSTOMER_ID`, `ACQUISITION_DATE`, `CUSTOMER_SEGMENT_SNAPSHOT`, `LEGACY_REGION_CODE`

## Project Setup

A dbt project already exists with the following configurations:

- DuckDB project location: `/app/dbt_models_duckdb`
- Snowflake project location: `/app/dbt_models_snowflake`

All the required staging models are already implemented and available for use.

## Existing Staging Models

**Staging** (`models/staging/`):
- `stg_analytics__fact_sales.sql`
- `stg_analytics__dim_customer.sql`
- `stg_analytics__dim_date.sql`
- `stg_customer__customers.sql`

## Required Models

**Intermediate** (`models/intermediate/`):
- `int_analytics__fact_sales.sql`
- `int_customer__customers.sql`

**Marts** (`models/marts/`):
- `customer_cohorts.sql`
- `cohort_retention.sql`
- `customer_clv.sql`

## Output Requirements

**customer_cohorts** must contain:
- `customer_id` - unique customer identifier
- `cohort_month` - month of first transaction (YYYY-MM format string)
- `first_transaction_date` - date of first transaction
- `first_transaction_amount` - amount of first transaction
- `signup_to_first_purchase_days` - days between signup and first purchase (integer, 0 if same day)
- `acquisition_channel` - derived from region: 'NORTH'->'Online', 'SOUTH'->'Retail', 'EAST'->'Partner', 'WEST'->'Direct', NULL or unrecognized->'Unknown'

**cohort_retention** must contain:
- `cohort_month` - the cohort (YYYY-MM format string)
- `period_number` - months since cohort month (integer, starting at 0)
- `period_month` - the actual month of activity (YYYY-MM format string)
- `cohort_size` - number of customers in the cohort (at period 0)
- `active_customers` - customers with transactions in this period
- `retained_customers` - customers active in this period who were also active in the previous period
- `retention_rate` - active_customers / cohort_size, rounded to 4 decimals
- `period_revenue` - total revenue in this period from cohort customers
- `cumulative_revenue` - running total of revenue for this cohort through this period

**customer_clv** must contain:
- `customer_id` - unique customer identifier
- `cohort_month` - customer's cohort
- `total_transactions` - count of all transactions
- `total_revenue` - sum of all transaction amounts
- `avg_transaction_value` - average transaction amount, rounded to 2 decimals
- `customer_lifespan_months` - the inclusive count of months from first to last transaction (months difference + 1). Minimum 1.
- `monthly_revenue_rate` - total_revenue / customer_lifespan_months, rounded to 2 decimals
- `months_since_last_transaction` - months from last transaction to reference date (2024-12-31)
- `churn_probability` - calculated churn score (see Business Rules), rounded to 2 decimals
- `predicted_clv_12m` - 12-month predicted CLV (see Business Rules), rounded to 2 decimals
- `customer_tier` - based on predicted_clv_12m:
  - 'Platinum': >= 1000
  - 'Gold': >= 500
  - 'Silver': >= 100
  - 'Bronze': < 100

## Business Rules

### 1. Cohort Assignment
- A customer's cohort is determined by the **month of their first transaction**.
- Cohort month format: 'YYYY-MM'
- If a customer has no transactions, they should not appear in any output.

### 2. Retention Calculation
- **Period 0** is the cohort month itself.
- A customer is "active" in a period if they have at least one transaction in that calendar month.
- **retained_customers** counts customers who are active in BOTH the current period AND the immediately preceding period (period N requires activity in both period N and period N-1). For period 0, retained_customers = active_customers.
- Generate periods from 0 up to the maximum observed period for each cohort.

### 3. Churn Probability Scoring
To estimate churn probability for each customer, consider three main factors:

1. **Recency**: The number of months since the customer's last transaction. The longer it has been, the higher the base risk of churn. Divide this number by 12 to get a base score.

2. **Frequency**: Adjust the risk based on how many transactions the customer has made in total.
   - 10 or more transactions: Multiplier **0.7**
   - 5 to 9 transactions: Multiplier **0.85**
   - 2 to 4 transactions: Multiplier **1.0**
   - 1 transaction: Multiplier **1.3**

3. **Recency Adjustment**: Further adjust the risk based on how recent the last transaction was (months_since_last_transaction).
   - <= 1 month: Multiplier **0.5**
   - <= 3 months: Multiplier **0.8**
   - <= 6 months: Multiplier **1.0**
   - > 6 months: Multiplier **1.2**

Combine these factors by multiplying the base score by the frequency and recency multipliers. If the result is greater than 1.0, cap the churn probability at 1.0. Round the final value to two decimal places.

### 4. Predicted Customer Lifetime Value (CLV)
The 12-month predicted CLV estimates the revenue a customer will generate over the next 12 months, accounting for their churn risk.

Calculate `predicted_clv_12m` using this formula:

**predicted_clv_12m = monthly_revenue_rate x 12 x (1 - churn_probability)**

Where:
- `monthly_revenue_rate` is the customer's total revenue divided by their lifespan in months
- `churn_probability` is calculated as described in Business Rule #3
- The result should be rounded to 2 decimal places

This formula projects the customer's monthly revenue rate over 12 months, then discounts it by their probability of remaining active (1 - churn_probability).

## Validation and Quality Requirements

### Data Quality Standards
Your solution will be validated against expected outputs calculated from the source data. The validation process samples records from each output table and verifies that your calculations match the expected results within acceptable tolerances.

**Passing Criteria**: At least **80% of sampled records** must validate successfully for each output table (customer_cohorts, cohort_retention, customer_clv). This allows for minor edge case variations while ensuring the core logic is correct.

### Idempotency
Your dbt models must be **idempotent**, meaning that running the pipeline multiple times with the same source data must produce identical results. This is a critical requirement for production data pipelines. Ensure your models use deterministic logic and avoid non-deterministic functions (like random number generators or current timestamps where not appropriate).

## Guidelines

- Use Jinja `{% if target.type == 'snowflake' %}` for DuckDB-specific functions (strftime vs TO_CHAR, date subtraction vs DATEDIFF, etc.)
