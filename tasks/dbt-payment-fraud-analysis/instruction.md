# Payment Fraud Detection Analysis

The Risk Management team is building a fraud prevention dashboard. "We have fraud scores per order, but I need to connect them to payment patterns. Flag any payment that looks suspicious - high amounts, high fraud scores, failed transactions, or customers with unusually high payment velocity."

## Your Task

Create a dbt project at `/app/dbt_project` with fraud analysis models in schema `fraud_analytics`.

## Files
- DuckDB: Create models at `/app/dbt_project/models/`
- Snowflake: Create models at `/app/dbt_project/models/`

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

## Requirements

- Use `ORDERS.ORDER_PAYMENTS`, `ORDERS.ORDERS`, and `ORDERS.ORDER_FRAUD_SCORES`
- Calculate payment velocity per customer (payments per day, amount per day)
- Flag high velocity: payments_per_day > 0.5 OR amount_per_day > 500
- Detect anomalies: HIGH_AMOUNT (>1000), HIGH_FRAUD_SCORE (>70), CRITICAL_RISK (risk_level is CRITICAL or HIGH), FAILED_PAYMENT, HIGH_VELOCITY_CUSTOMER

## Output Columns

**payment_method_summary**: `payment_method`, `total_transactions`, `total_amount`, `avg_transaction_amount`, `success_count` (CAPTURED/COMPLETED), `failed_count`, `pending_count`, `failure_rate` (0.0-1.0)

**customer_payment_velocity**: `customer_id`, `total_payments`, `total_amount`, `distinct_payment_methods`, `first_payment_date`, `last_payment_date`, `days_active` (min 1), `payments_per_day`, `amount_per_day`, `max_single_payment`, `is_high_velocity`

**Important calculation notes for customer_payment_velocity:**
- Use `PROCESSED_AT` as the payment date for all date-based calculations. Do NOT use `created_at` or `coalesce(processed_at, created_at)`.
- Calculate `days_active` as `GREATEST(DATEDIFF('day', MIN(processed_at), MAX(processed_at)), 1)` — do NOT add 1 to the DATEDIFF result. The GREATEST ensures a minimum value of 1 for customers with only one payment.

**fraud_risk_summary**: `risk_level`, `order_count`, `total_payment_amount`, `avg_fraud_score`, `failed_payment_count`, `pct_of_total_orders`

**payment_anomalies** (at least 1 flag): `payment_id`, `order_id`, `customer_id`, `payment_method`, `amount`, `processed_at`, `fraud_score`, `risk_level`, `anomaly_flags` (comma-separated), `anomaly_count`

## Guidelines
- The SQL syntax should work on both DuckDB and Snowflake (ANSI SQL compatible)
