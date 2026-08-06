# Late-Arriving Orders Reconciliation

## Background

In enterprise accounting systems, orders sometimes arrive in the system after the accounting period in which they were actually placed. This creates revenue recognition issues - the revenue should be recognized in the period when the order was placed (ORDERED_AT), not when it was entered into the system (CREATED_AT).

Your company needs to identify these late-arriving orders and generate adjustment entries to correct the revenue allocation across GL periods.

## Task

Identify orders that were entered into the system in a different GL period than when they were actually ordered, and calculate the necessary adjustment entries to correct the revenue recognition for each affected period.

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

## Database Connection

You must connect to the database based on `DB_TYPE`:

### DuckDB Connection
Use `duckdb.connect()` with the path from `$DUCKDB_PATH`.

### Snowflake Connection
Use `snowflake.connector.connect()` with password authentication:
- Use the environment variables for account, user, database, schema, warehouse, and role

## Data Sources

The database contains the following tables:

- **ORDERS.ORDERS** - Order data with identifiers, timestamps (ORDERED_AT, CREATED_AT), monetary amounts (GRAND_TOTAL), currency information (CURRENCY_CODE, EXCHANGE_RATE), and status. Explore the table to understand all available columns.

- **FINANCE.GL_PERIODS** - Accounting periods with period identifiers, names (YYYY-MM format), fiscal year/month, date boundaries (START_DATE, END_DATE), and status. Explore the table to understand all available columns.

- **FINANCE.CURRENCY_EXCHANGE_RATES** - Historical exchange rates with currency pairs and effective dates. Explore the table to understand all available columns.

## Requirements

1. **Identify late-arriving orders**:
   - An order is "late-arriving" if ORDERED_AT falls in a different GL period than CREATED_AT
   - Only consider orders with STATUS in ('COMPLETED', 'DELIVERED', 'SHIPPED')

2. **Calculate revenue adjustments**:
   - For the period where the order was CREATED_AT: Generate a REVERSAL entry (negative amount)
   - For the period where the order was ORDERED_AT: Generate a RECOGNITION entry (positive amount)
   - Convert all amounts to USD using the exchange rate at the order date

3. **Handle multi-currency orders**:
   - Use the EXCHANGE_RATE from the orders table to convert to USD
   - If exchange rate is NULL or 0, use 1.0 (assume USD)

4. **Calculate cumulative impact**:
   - For each period, sum all adjustments (both positive and negative)
   - Track the net impact on each period's revenue

5. **Output columns** (CSV format):
   - `period_id`: The GL period ID
   - `period_name`: Period name (YYYY-MM format)
   - `adjustment_type`: 'REVERSAL' (negative, removes revenue from created_at period) or 'RECOGNITION' (positive, adds revenue to ordered_at period)
   - `order_count`: Number of orders in this adjustment
   - `original_amount_local`: Sum of GRAND_TOTAL in original currencies
   - `adjusted_amount_usd`: Sum of GRAND_TOTAL converted to USD
   - `variance_reason`: Description of why adjustment is needed

6. **Include summary row**:
   - Add a final row with period_id = 'TOTAL' showing net impact across all periods
   - The TOTAL summary row must use `adjustment_type = 'SUMMARY'`
   - The total of RECOGNITION amounts should equal the total of REVERSAL amounts (balanced adjustments)

7. **Output file**: `/app/late_orders_adjustments.csv`
   - CSV column headers must be lowercase (e.g. `period_id`, not `PERIOD_ID`)

## Special Cases

- **Year-end crossing**: Orders placed in December but entered in January require special attention as they cross fiscal years
- **Same-period entries**: If ORDERED_AT and CREATED_AT are in the same GL period, no adjustment is needed
- **Future periods**: Ignore any orders where ORDERED_AT would be in a period after CREATED_AT (data quality issue)

## Notes

- Ensure all monetary values are rounded to 2 decimal places
- Sort output by period_name, then adjustment_type

## Guidelines

- Use `DATEDIFF('day', start, end)` instead of date subtraction for cross-DB compatibility
- Use `CAST(col AS DATE)` or `CAST(col AS TIMESTAMP)` for date type conversions
- Handle `DB_TYPE` environment variable to determine which backend to connect to
