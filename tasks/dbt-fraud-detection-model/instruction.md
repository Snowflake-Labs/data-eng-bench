# Fraud Detection Model

The fraud team just got out of a budget meeting: "We're losing $50K/month to fraud and our current rules are too basic. We need a smarter system that looks at order patterns, customer history, and shipping anomalies. Build something that gives us a risk score we can actually act on."

## Your Task

Create a dbt model `fraud_flagged_orders` in schema `fraud_analytics` that identifies potentially fraudulent orders.

## Environment

- **DuckDB database**: `/app/database/retail.duckdb`
- **DuckDB dbt project**: `/app/dbt_models_duckdb`
- **Snowflake dbt project**: `/app/dbt_models_snowflake`
- **Schema**: `fraud_analytics`

(Hint: If your models appear in a different schema than expected, re-check your work and review how dbt handles schema naming when a custom schema is specified.)

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

## Source Data

Explore the `main` schema to find tables containing:
- Orders (with totals, timestamps, address references, and chargeback/first-order flags)
- Order line items (quantities per order)
- Addresses (for billing/shipping state comparison)

### Snowflake Source Schemas

In Snowflake, the source tables are in different schemas:
- `ORDERS.ORDERS` - Orders table
- `ORDERS.ORDER_LINES` - Order line items
- `RAW_SFDC.ADDRESSES` - Addresses

## Fraud Signals to Detect

1. **High Value Order**: `grand_total` > $1500
2. **Bulk Quantity**: More than 5 items total in a single order
3. **Velocity Fraud**: Customer placed 2+ orders on the same calendar day (use window functions)
4. **Address Mismatch**: Shipping state differs from billing state (both must be non-NULL)
5. **First-Time High Value**: Customer's first ever order AND grand_total > $500 (use the first-order flag from source data)
6. **Risky Customer History**: Customer has ANY order (including current) with `chargeback_flag = TRUE`

## Output Columns

| Column | Description |
|--------|-------------|
| order_id | Order identifier |
| customer_id | Customer identifier |
| ordered_at | Order timestamp |
| grand_total | Order total (2 decimal places) |
| total_items | Sum of quantity_ordered for this order |
| orders_same_day | Count of orders by this customer on same calendar day |
| billing_state | State from billing address |
| shipping_state | State from shipping address |
| is_high_value | TRUE if grand_total > 1500 |
| is_bulk_order | TRUE if total_items > 5 |
| is_velocity_fraud | TRUE if orders_same_day >= 2 |
| is_address_mismatch | TRUE if billing_state != shipping_state (FALSE if either is NULL) |
| is_first_order_high_value | TRUE if this is customer's first order AND grand_total > 500 |
| has_chargeback_history | TRUE if customer has ANY order with chargeback_flag = TRUE (including current) |
| fraud_flags_count | Count of TRUE flags (0-6) |
| fraud_risk_level | CRITICAL (>=4), HIGH (3), MEDIUM (2), LOW (1), NONE (0) |

## Model Naming

Use these exact model names:
- **Staging**: `stg_fd_orders`, `stg_fd_order_lines`, `stg_fd_addresses`
- **Mart**: `fraud_flagged_orders`

## Requirements

- Include ALL orders in the output (not just flagged ones)
- Handle NULL addresses gracefully
- Use window functions for velocity detection
- Ensure deterministic ordering by order_id

## Guidelines

- Use Jinja `{% if target.type == 'snowflake' %}` for any database-specific syntax differences

Install additional libraries as needed.
