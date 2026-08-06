# Customer Lifetime Value Bug Fix

The company's customer lifetime value (LTV) metrics are incorrect. Finance has reported that customer LTV values are overstated, which is affecting customer segmentation and marketing spend decisions.

## Environment

### Database Backend
This task supports two database backends:

- **DuckDB**: Local DuckDB database at `/app/database/retail.duckdb`. The dbt project is at `/app/dbt_models_duckdb/`.
- **Snowflake**: Cloud Snowflake database. Connection details are provided via environment variables (`SNOWFLAKE_ACCOUNT`, `SNOWFLAKE_USER`, `SNOWFLAKE_PASSWORD`, `SNOWFLAKE_DATABASE`, `SNOWFLAKE_SCHEMA`, `SNOWFLAKE_WAREHOUSE`, `SNOWFLAKE_ROLE`). The dbt project is at `/app/dbt_models_snowflake/`.

Check the `DB_TYPE` environment variable to determine which backend is active.

### dbt Profile Setup

Create a `profiles.yml` in the appropriate dbt project directory:

- For DuckDB: Configure with `type: duckdb` and `path` pointing to the database file. Profile name: `retail_dw_master`.
- For Snowflake: Configure with `type: snowflake` and use the environment variables for connection settings (password authentication). Profile name: `retail_dw_master`. Set the profile's `schema:` to `$SNOWFLAKE_SCHEMA` — do NOT leave it blank (a blank schema makes Snowflake default to `PUBLIC`, so models land in the wrong schema and the verifier cannot find them).

## Your Task

Investigate the database to understand the data model and identify what's causing LTV to be overstated. Then create a dbt model that produces a corrected `customer_ltv` table in the `main` schema.

LTV should only include revenue from orders that resulted in actual revenue for the company. Investigate the data to understand which orders should be excluded from the calculation.

## Required Output

### `main.customer_ltv`

| Column | Type | Description |
|--------|------|-------------|
| `customer_id` | VARCHAR | Unique customer identifier |
| `total_orders` | INTEGER | Count of valid orders |
| `lifetime_value` | DECIMAL | Sum of order value for valid orders only |
| `avg_order_value` | DECIMAL | Average order value |
| `first_order_date` | DATE | Date of first valid order |
| `last_order_date` | DATE | Date of most recent valid order |
| `value_segment` | VARCHAR | Customer segment based on LTV |

### Value Segment Rules

Assign customers to segments based on their corrected `lifetime_value`:
- `'VIP'` - lifetime_value >= 1000
- `'High Value'` - lifetime_value >= 500 and < 1000
- `'Medium Value'` - lifetime_value >= 100 and < 500
- `'Low Value'` - lifetime_value > 0 and < 100
- `'No Value'` - lifetime_value = 0 or NULL

## Notes

- Round decimal values to 2 decimal places
- Include all customers, even those with no valid orders
- Customers with no valid orders should have `lifetime_value = 0`, `total_orders = 0`, and `value_segment = 'No Value'`
- The `avg_order_value` should be 0 for customers with no orders
- Do NOT modify upstream staging models
- Preserve all output columns
