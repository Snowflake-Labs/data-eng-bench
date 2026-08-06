# Build Payment Method Analytics Model

## Overview

Create a new dbt model that analyzes payment method performance across orders to identify payment patterns, success rates, reliability metrics, and peer comparisons across payment providers.

## Files

- DuckDB: `/app/dbt_models_duckdb/models/marts/sales/rpt_payment_analytics.sql`
- Snowflake: `/app/dbt_models_snowflake/models/marts/sales/rpt_payment_analytics.sql`

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

## Requirements

### Data Sources

Use these tables:

- `int_sales__orders_enriched` - Orders with customer info (exclude cancelled orders: status values include both `'CANCELLED'` and abbreviation `'C'`)
- `stg_orders__order_payments` - Payment transactions (payment_id, order_id, payment_method, AMOUNT, status)

### Payment Status Values

The `status` column contains: `'AUTHORIZED'`, `'CAPTURED'`, `'COMPLETED'`, `'FAILED'`, `'PENDING'`

### Base Metrics (per payment method)

| Metric                 | Description                               |
| ---------------------- | ----------------------------------------- |
| total_transactions     | Count of payment transactions             |
| total_orders           | Distinct orders using this payment method |
| total_amount           | Sum of all payment amounts                |
| successful_amount      | Sum for COMPLETED or CAPTURED payments    |
| failed_transactions    | Count of FAILED payments                  |
| pending_transactions   | Count of PENDING or AUTHORIZED payments   |
| success_rate           | Proportion successful (0-1)               |
| avg_transaction_amount | Average payment amount                    |
| failure_rate           | Proportion failed (0-1)                   |

### Provider Type Classification

Classify payment methods into provider groups based on the payment method name:

| Metric        | Description                             |
| ------------- | --------------------------------------- |
| provider_type | Category: CARD, DIGITAL, BANK, or OTHER |

Classify `provider_type` using these keyword rules (case-insensitive match against the payment method name):
- **CARD**: contains any of: CREDIT, DEBIT, CARD, VISA, MASTERCARD, AMEX, DISCOVER
- **DIGITAL**: contains any of: PAYPAL, VENMO, APPLE, GOOGLE, WALLET
- **BANK**: contains any of: BANK, ACH, WIRE, TRANSFER
- **OTHER**: anything that doesn't match the above categories

### Peer Comparison Metrics

Compare each payment method against others in the SAME provider_type:

| Metric                     | Description                                              |
| -------------------------- | -------------------------------------------------------- |
| provider_success_rank      | Rank by success_rate within provider (1 = best, no gaps) |
| provider_method_count      | Total methods in same provider_type                      |
| above_provider_avg_success | 1 if above provider average, 0 otherwise                 |
| provider_volume_percentile | Volume percentile within provider (0-1)                  |

### Reliability Score Formula

```
reliability_score = (success_rate * 0.40 + (1 - failure_rate) * 0.30 + volume_factor * 0.15 + amount_factor * 0.15) * 100
```

Where:

- `volume_factor = MIN(total_transactions / 1000, 1.0)`
- `amount_factor = MIN(avg_transaction_amount / 500, 1.0)`

### Classification

**payment_health_tier** - Waterfall classification (check conditions in order, first match wins):

1. `'critical'` - failure_rate >= 0.15 OR success_rate < 0.70
2. `'problematic'` - failure_rate >= 0.08 OR below provider avg success
3. `'concerning'` - failure_rate >= 0.03 OR success_rate < 0.90
4. `'excellent'` - reliability percentile >= 0.75 within provider AND failure_rate < 0.02
5. `'good'` - above provider avg success AND reliability_score >= 60
6. `'concerning'` - default fallback

## Expected Output

| Column                     | Type    |
| -------------------------- | ------- |
| payment_method             | varchar |
| provider_type              | varchar |
| total_transactions         | integer |
| total_orders               | integer |
| total_amount               | decimal |
| successful_amount          | decimal |
| failed_transactions        | integer |
| pending_transactions       | integer |
| success_rate               | decimal |
| avg_transaction_amount     | decimal |
| failure_rate               | decimal |
| provider_success_rank      | integer |
| provider_method_count      | integer |
| above_provider_avg_success | integer |
| provider_volume_percentile | decimal |
| reliability_score          | decimal |
| payment_health_tier        | varchar |

## Validation

- Model compiles and runs successfully
- All payment methods with transactions must be included
- No invalid values (infinity, NaN)
- Peer metrics partitioned by provider_type
- Scores bounded appropriately
- use `percent_rank()` and `dense_rank()` accordingly
