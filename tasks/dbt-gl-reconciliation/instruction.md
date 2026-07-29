# GL Reconciliation and Trial Balance

The Controller is concerned about month-end close accuracy. "Our auditors flagged that some journal entries don't balance, and a few accounts have balances in the wrong direction. I need a trial balance report plus models that identify these issues before external audit. I also need period-by-period activity summaries for trend analysis."

## Your Task

Create a dbt project at `/app/dbt_project` with reconciliation models in schema `gl_analytics`.

(Hint: If your models appear in a different schema than expected, re-check your work and review how dbt handles schema naming when a custom schema is specified.)

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

## Source Data

Explore the `FINANCE` schema to find tables containing:
- General ledger transactions (with debits, credits, account references, period references)
- Chart of accounts (account types, subtypes, names)
- Fiscal periods (period definitions with dates and status)

## Requirements

Create 5 dbt models:

### 1. account_balances
- Aggregate all transactions by account
- Calculate net_balance based on account type:
  - ASSET/EXPENSE: debits - credits
  - LIABILITY/EQUITY/REVENUE: credits - debits

### 2. trial_balance
- Single row summarizing total debit balances vs credit balances
- Calculate the difference and flag if balanced (within 0.01 tolerance)

### 3. out_of_balance_entries
- Identify ALL journal entries where total debits != total credits (imbalance > 0.01)
- Include single-line entries (which are inherently out of balance)
- Group by transaction identifier

### 4. unusual_balance_accounts
- Flag accounts where the actual balance direction differs from expected
- Filter to only show accounts that ARE unusual (is_unusual = TRUE)

### 5. period_summary (NEW)
- Summarize GL activity by fiscal period
- Join transactions with period definitions
- Calculate period totals and period-over-period changes

## Unusual Balance Direction Logic

To determine if an account has an unusual balance direction:

1. **Calculate actual_direction** using raw transaction totals (debits - credits):
   - If raw_balance > 0.01 -> actual_direction = 'DEBIT'
   - If raw_balance < -0.01 -> actual_direction = 'CREDIT'
   - Otherwise -> skip (balance is essentially zero)

2. **Determine expected_direction** based on account type and subtype:
   - ASSET (non-CONTRA): expects DEBIT
   - ASSET CONTRA: expects CREDIT
   - LIABILITY: expects CREDIT
   - EQUITY: expects CREDIT
   - REVENUE (non-CONTRA): expects CREDIT
   - REVENUE CONTRA: expects DEBIT
   - EXPENSE: expects DEBIT

3. **Flag as unusual** if actual_direction != expected_direction

The `account_subtype` column indicates if an account is a CONTRA account.

## Output Columns

**account_balances**: `account_id`, `account_number`, `account_name`, `account_type`, `total_debits`, `total_credits`, `net_balance`

**trial_balance**: `total_debit_balances`, `total_credit_balances`, `difference`, `is_balanced`

**out_of_balance_entries**: `transaction_number`, `entry_date`, `total_debits`, `total_credits`, `imbalance_amount`, `line_count`

**unusual_balance_accounts**: `account_id`, `account_number`, `account_name`, `account_type`, `account_subtype`, `net_balance`, `expected_direction`, `actual_direction`, `is_unusual`

**period_summary**: `period_id`, `period_name`, `fiscal_year`, `fiscal_quarter`, `fiscal_month`, `start_date`, `end_date`, `period_status`, `total_debits`, `total_credits`, `net_activity`, `transaction_count`, `prior_period_net_activity`, `activity_change`

## Guidelines
- The SQL syntax should work on both DuckDB and Snowflake (ANSI SQL compatible)
- Use standard SQL functions that are supported by both databases
