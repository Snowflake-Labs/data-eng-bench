# Customer Account Balance Ledger with Risk Analysis

Finance needs a comprehensive account ledger with advanced risk assessment. Track every transaction, analyze payment patterns, calculate risk metrics, and identify problematic accounts.

## Files

- DuckDB: `/app/dbt_project` (create project here)
- Snowflake: `/app/dbt_project` (create project here)
- Target schema: `finance_analytics`

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

## Project Setup

1. Create a dbt project at `/app/dbt_project`
2. Configure `profiles.yml` to connect to the database with schema `finance_analytics`
3. Do not add `+schema` in `dbt_project.yml` (only set schema in profiles.yml)

## Source Data

1. **Orders**: Customer purchases
   - DuckDB: `main.orders`
   - Snowflake: `ORDERS.ORDERS`
   - Filter: `status NOT IN ('CANCELLED', 'FAILED')`
   - Key columns: `order_id`, `customer_id`, `ordered_at`, `grand_total`, `status`

2. **Payments**: Customer payments
   - DuckDB: `main.CUSTOMER_PAYMENTS`
   - Snowflake: `FINANCE.CUSTOMER_PAYMENTS`
   - Filter: `status = 'POSTED'`
   - Key columns: `payment_id`, `customer_id`, `payment_date`, `amount`, `status`

## Required Models

### 1. customer_running_balance

| Column | Description |
|--------|-------------|
| `transaction_id` | Order or payment ID |
| `customer_id` | Customer identifier |
| `transaction_type` | 'ORDER' or 'PAYMENT' |
| `transaction_date` | Date of transaction |
| `transaction_amount` | Positive for orders, negative for payments |
| `previous_balance` | Balance before transaction (0 for first) |
| `running_balance` | Balance after transaction |
| `transaction_sequence` | Sequential number per customer |
| `balance_status` | 'CREDIT' if < 0, 'ZERO' if = 0, 'DEBIT' if > 0 |
| `days_since_last_payment` | Days since most recent prior payment (NULL if none) |
| `is_high_balance` | TRUE/1 if running_balance > 500 |
| `balance_change_direction` | 'INCREASE', 'DECREASE', or 'NO_CHANGE' |
| `cumulative_orders` | Running count of orders |
| `cumulative_payments` | Running count of payments |
| `is_first_transaction` | TRUE/1 if transaction_sequence = 1 |
| `balance_trend` | 'IMPROVING' if balance decreased, 'WORSENING' if increased, 'STABLE' |
| `consecutive_orders` | Count of consecutive ORDER transactions ending at this row (resets on PAYMENT) |
| `consecutive_payments` | Count of consecutive PAYMENT transactions ending at this row (resets on ORDER) |
| `days_since_first_transaction` | Days between this transaction and customer's first transaction |

### 2. rpt_customer_account_summary

| Column | Description |
|--------|-------------|
| `customer_id` | Customer identifier |
| `total_orders` | Count of ORDER transactions |
| `total_payments` | Count of PAYMENT transactions |
| `total_order_amount` | Sum of order amounts |
| `total_payment_amount` | Sum of payment amounts (absolute value) |
| `final_balance` | Customer's current balance |
| `final_status` | Balance status of final transaction |
| `avg_days_between_payments` | Average days between consecutive payments (NULL if < 2 payments) |
| `max_balance_reached` | Highest running_balance recorded |
| `account_health_score` | 1-5: 5 if balance <= 0, 4 if <= 100, 3 if <= 300, 2 if <= 500, 1 if > 500 |
| `longest_order_streak` | Maximum consecutive orders without payment |
| `account_age_days` | Days between first and last transaction |

### 3. rpt_risk_assessment

| Column | Description |
|--------|-------------|
| `customer_id` | Customer identifier |
| `final_balance` | Current balance |
| `payment_frequency` | 'HIGH' if avg_days_between_payments < 15, 'MEDIUM' if < 45, 'LOW' if >= 45 or NULL |
| `balance_volatility` | 'HIGH' if max_balance_reached > 3 * final_balance, 'MEDIUM' if > 1.5x, 'LOW' otherwise |
| `streak_risk` | 'HIGH' if longest_order_streak >= 5, 'MEDIUM' if >= 3, 'LOW' otherwise |
| `overall_risk_score` | 1-10: sum of (payment_freq: HIGH=3/MED=2/LOW=1) + (volatility: HIGH=4/MED=2/LOW=1) + (streak: HIGH=3/MED=2/LOW=1) |
| `risk_category` | 'CRITICAL' if overall >= 9, 'HIGH' if >= 7, 'MEDIUM' if >= 5, 'LOW' otherwise |

## Business Rules

1. Orders INCREASE balance, payments DECREASE balance
2. All amounts rounded to 2 decimal places
3. Deterministic and idempotent results
4. Transaction ordering: by date, then by transaction_id for ties

## Output Expectations

- Total transactions: 3691
- All balance calculations mathematically accurate

## Guidelines

- The SQL syntax should work on both DuckDB and Snowflake (ANSI SQL compatible)
- Use `DATEDIFF('day', start, end)` for Snowflake and date subtraction for DuckDB when calculating day differences
- Use integer 1/0 instead of boolean TRUE/FALSE for cross-database compatibility
- Ensure idempotent execution (multiple runs produce same results)
- Handle NULL values appropriately
