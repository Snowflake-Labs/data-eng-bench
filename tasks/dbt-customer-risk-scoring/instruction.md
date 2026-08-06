# Customer Risk Scoring Model

The risk management team needs a customer risk scoring model to identify potentially risky customers based on their order behavior. Your goal is to build a dbt model that scores every customer by analyzing patterns in their order history.

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

## Environment

- dbt project location: `/app/dbt_project`
- Analysis date: Use `2024-12-01` as the reference date

### DuckDB
- Output schema: `risk_analytics`

### Snowflake
- Output schema: `main`

## dbt Profile Setup

You must configure dbt to connect to the database:

### DuckDB Profile
- Create a `profiles.yml` with profile name `dbt_project`
- Configure with `type: duckdb` and the database path
- Set schema to `risk_analytics`

### Snowflake Profile
- Use the pre-built project at `/app/dbt_models_snowflake` as the base
- Create a symlink: `ln -sfn /app/dbt_models_snowflake /app/dbt_project`
- Configure `profiles.yml` in the project directory with profile name `retail_dw_master`
- Configure with `type: snowflake` using password authentication:
  - Use the environment variables for account, user, password, database, schema, warehouse, and role
  - Set schema to `main`

## Data Exploration

Build from customer order history available in the warehouse. You will need to explore the available tables and their schemas to understand the data model. For DuckDB, look in the `main` schema. For Snowflake, explore the available schemas to find the relevant order and customer tables.

Pay attention to column types, as flag columns (e.g., `chargeback_flag`) may be stored differently across backends.

## Risk Scoring Rules

Customers accumulate risk points based on the following criteria:

1. **Late Payments** (+10 points each): Orders where `payment_status = 'UNPAID'`
2. **Returns** (+5 points each): Orders with `status = 'RETURNED'` (count from the orders table, not a separate returns table)
3. **Chargebacks** (+20 points each): Orders where `chargeback_flag = TRUE`

The total risk score is calculated as:

```
risk_score = (late_payment_count * 10) + (return_count * 5) + (chargeback_count * 20)
```

Assign risk tiers based on the score:

- `'LOW'`: risk_score < 20
- `'MEDIUM'`: risk_score >= 20 AND risk_score < 50
- `'HIGH'`: risk_score >= 50 AND risk_score < 100
- `'CRITICAL'`: risk_score >= 100

## Required Models

### Staging Models (models/staging/)

Create staging models to clean and prepare the source data:
- **`stg_orders_risk`** - Orders staging model with cleaned/trimmed string fields
- **`stg_customers_risk`** - Customers staging model with trimmed name fields

Define appropriate sources for each schema.

### Marts (models/marts/)

**customer_risk_scores.sql** - Final risk scoring model with columns:
- `customer_id`
- `customer_name` (concatenate first_name and last_name)
- `late_payment_count` - Number of unpaid orders
- `return_count` - Number of returned orders
- `chargeback_count` - Number of orders with chargebacks
- `risk_score` - Total risk points (see formula above)
- `risk_tier` - Category based on score boundaries (see tiers above)

## Output Requirements

1. Include ALL customers (even those with zero risk score)
2. No NULL values in any column (use 0 for counts where applicable)
3. Exactly one row per customer
4. Risk scores must be non-negative integers

## Guidelines
- Use `trim()`, `coalesce()`, `cast()` which work on both backends
- For boolean flag comparisons, use a pattern that works across backends (e.g., `UPPER(CAST(flag AS VARCHAR)) IN ('TRUE', '1', 'T', 'Y', 'YES')` for Snowflake compatibility)
- For Snowflake, run dbt with `--select` specifying model names explicitly
