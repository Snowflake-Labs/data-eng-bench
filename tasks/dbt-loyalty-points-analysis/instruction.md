# Loyalty Points Program Analytics

Build a dbt project that analyzes loyalty points transactions by program to measure engagement and liability.

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

- DuckDB: Database at `/app/database/retail.duckdb`
- Snowflake: Use pre-configured environment variables
- dbt project location: `/app/dbt_project` (DuckDB) or `/app/dbt_models_snowflake` (Snowflake)
- Output schema: `loyalty_analytics`

## dbt Profile Setup

You must configure dbt to connect to the database:
- Create a `profiles.yml` in the dbt project directory with the appropriate profile name
- Set `DBT_PROFILES_DIR` environment variable to the directory containing `profiles.yml`

### DuckDB Profile
Configure with `type: duckdb` and the database path from `$DUCKDB_PATH`.

### Snowflake Profile
Configure with `type: snowflake` using password authentication:
- Use the environment variables for account, user, password, database, schema, warehouse, and role
- Profile name: `retail_dw_master`

## Source Tables

### DuckDB
The database contains the following tables in the `main` schema:

- `LOYALTY_POINTS_TRANSACTIONS` - Transaction records with: transaction_id, customer_id, program_id, transaction_type, points, balance_after, order_id, description, expires_at, created_at
- `LOYALTY_PROGRAMS` - Program details: program_id, program_name, program_type, points_per_dollar, points_value, is_active
- `CUSTOMERS` - Customer information: customer_id, first_name, last_name, email, status

### Snowflake
- `LOYALTY_POINTS_TRANSACTIONS` in the `MARKETING` schema
- `LOYALTY_PROGRAMS` in the `MARKETING` schema
- `CUSTOMERS` in the `CUSTOMER` schema

Transaction types include: EARN, REDEEM, EXPIRE, ADJUST, BONUS

## Requirements

Create a dbt project with the following structure:

### Configuration

- Configure `profiles.yml` to connect to the appropriate database
- Set schema to `loyalty_analytics` in profiles.yml only (not in dbt_project.yml)

### Staging Models (models/staging/)

Create staging models for transactions, programs, and customers:
- `stg_lp_transactions.sql` — staging for loyalty points transactions
- `stg_lp_programs.sql` — staging for loyalty programs
- `stg_lp_customers.sql` — staging for customers

Each staging model should include:
- Source definitions for the schema tables
- Cleaned/trimmed string fields

### Intermediate Model (models/intermediate/)

Create `int_loyalty_metrics.sql` that aggregates transaction data by program:
- Calculate points earned from EARN and BONUS transactions
- Calculate points redeemed as `SUM(ABS(points))` over REDEEM transactions — take the absolute value of each REDEEM transaction's points, then sum (i.e. `SUM(ABS(points))`, NOT `ABS(SUM(points))`)
- Calculate points expired as `SUM(ABS(points))` over EXPIRE transactions — take the absolute value of each EXPIRE transaction's points, then sum (i.e. `SUM(ABS(points))`, NOT `ABS(SUM(points))`)
- Count distinct customers per program

### Final Model (models/marts/)

Create `program_loyalty_summary.sql` as a table with:
- `program_id` - program identifier
- `program_name` - name from programs table
- `member_count` - distinct customers with transactions
- `points_earned` - total points earned
- `points_redeemed` - total redeemed (positive value)
- `points_expired` - total expired (positive value)
- `points_balance` - remaining liability, calculated as `points_earned − points_redeemed − points_expired` (do NOT include ADJUST transactions)
- `redemption_rate` - percentage of earned points that were redeemed
- `avg_points_per_member` - average balance per member (integer)

## Validation Requirements

- No NULL values in any output column
- Each program appears exactly once
- All point values must be non-negative
- Redemption rate between 0 and 100

## Guidelines

- The SQL syntax should work on the selected database backend
- For Snowflake, staging model names must be unique to avoid conflicts with existing base project models
