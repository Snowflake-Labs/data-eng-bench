# Payment Risk Scoring

Build dbt models for payment transaction risk analysis with fraud risk scoring and customer risk profiling.

## Your Task

Add dbt models to the existing project that create payment risk metrics.

## Files

- DuckDB: `/app/dbt_models_duckdb/models/intermediate/payments/` and `/app/dbt_models_duckdb/models/marts/payments/`
- Snowflake: `/app/dbt_models_snowflake/models/intermediate/payments/` and `/app/dbt_models_snowflake/models/marts/payments/`

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

## Source

Use existing staging models: stg_pos__* and stg_customer__* in models/staging/

## Required Models

### Intermediate Layer (`models/intermediate/payments/`)

#### int_transaction_velocity

One row per customer_id from stg_pos__transactions.

| Column | Description |
|--------|-------------|
| customer_id | Group key |
| total_transactions | Total number of transactions for this customer |
| total_amount | Sum of grand_total across all transactions |
| avg_transaction_amount | Average transaction amount, rounded to 2 decimals |
| max_transaction_amount | Maximum single transaction amount |
| min_transaction_amount | Minimum single transaction amount |
| distinct_days_with_transactions | Number of distinct dates with transactions |
| first_transaction_date | Earliest transaction date |
| last_transaction_date | Most recent transaction date |
| days_as_customer | Days between first and last transaction, default 0 if single transaction |
| avg_transactions_per_day | total_transactions divided by days_as_customer, default total_transactions if single day, rounded to 2 decimals |
| high_value_transaction_count | Number of transactions with grand_total > 500 |

#### int_payment_patterns

One row per customer_id from stg_pos__tenders and stg_pos__transactions.

| Column | Description |
|--------|-------------|
| customer_id | Group key |
| total_payments | Total number of payment records |
| unique_payment_methods | Count of distinct payment_method values |
| unique_cards | Count of distinct card_last_four values (excluding NULL) |
| successful_payments | Count of payments with status in ('CAPTURED', 'captured', 'AUTHORIZED', 'authorized', 'C', 'A') |
| failed_payments | Count of payments with status in ('FAILED', 'failed', 'F') |
| pending_payments | Count of payments with status in ('PENDING', 'pending', 'P') |
| payment_failure_rate | failed_payments divided by total_payments, default 0, rounded to 2 decimals |
| primary_card_type | Most frequently used card_type (mode), NULL if no cards |
| uses_multiple_cards | TRUE if unique_cards > 1 |
| card_type_diversity | Count of distinct card_type values (excluding NULL) |

#### int_customer_address_risk

One row per customer_id from stg_customer__customer_addresses and stg_pos__transactions.

| Column | Description |
|--------|-------------|
| customer_id | Group key |
| total_addresses | Count of addresses for this customer |
| verified_addresses | Count of addresses where is_verified = TRUE |
| unverified_addresses | Count of addresses where is_verified = FALSE or NULL |
| address_verification_rate | verified_addresses divided by total_addresses, default 0, rounded to 2 decimals |
| unique_countries | Count of distinct country_code values |
| unique_cities | Count of distinct city values |
| has_multiple_countries | TRUE if unique_countries > 1 |
| billing_shipping_mismatch_count | Count of transactions where billing_address_id != shipping_address_id |
| total_transactions_with_addresses | Count of transactions that have both billing and shipping address |
| mismatch_rate | billing_shipping_mismatch_count divided by total_transactions_with_addresses, default 0, rounded to 2 decimals |

### Marts Layer (`models/marts/payments/`)

#### transaction_risk_scores

One row per order_id from stg_pos__transactions with stg_pos__tenders and intermediate models.

| Column | Description |
|--------|-------------|
| order_id | From stg_pos__transactions |
| customer_id | From stg_pos__transactions |
| order_date | Date of ordered_at |
| transaction_amount | From stg_pos__transactions.grand_total |
| payment_method | From stg_pos__tenders |
| card_type | From stg_pos__tenders, NULL if not card payment |
| card_last_four | From stg_pos__tenders, NULL if not card payment |
| payment_status | From stg_pos__tenders.status |
| ip_address | From stg_pos__transactions |
| billing_address_id | From stg_pos__transactions |
| shipping_address_id | From stg_pos__transactions |
| is_billing_shipping_match | TRUE if billing_address_id = shipping_address_id or both NULL |
| customer_transaction_count | From int_transaction_velocity.total_transactions |
| customer_failure_rate | From int_payment_patterns.payment_failure_rate |
| customer_address_verification_rate | From int_customer_address_risk.address_verification_rate |
| is_high_value | TRUE if transaction_amount > 500 |
| is_new_customer | TRUE if customer has <= 2 total_transactions |
| risk_score | Weighted risk score (see below) |
| risk_tier | 'HIGH' if risk_score >= 70, 'MEDIUM' if >= 40, 'LOW' otherwise |
| review_priority | Priority score for manual review (see below) |
| requires_review | TRUE if risk_tier = 'HIGH' or review_priority >= 80 |

#### customer_risk_profile

One row per customer_id from stg_pos__transactions with all intermediate models.

| Column | Description |
|--------|-------------|
| customer_id | Group key |
| total_transactions | From int_transaction_velocity |
| total_spend | From int_transaction_velocity.total_amount |
| avg_transaction_amount | From int_transaction_velocity |
| days_as_customer | From int_transaction_velocity |
| transaction_frequency_score | Normalized score based on avg_transactions_per_day (see below) |
| payment_failure_rate | From int_payment_patterns |
| uses_multiple_cards | From int_payment_patterns |
| card_diversity_count | From int_payment_patterns.card_type_diversity |
| address_verification_rate | From int_customer_address_risk |
| has_multiple_countries | From int_customer_address_risk |
| billing_shipping_mismatch_rate | From int_customer_address_risk.mismatch_rate |
| velocity_risk_score | Risk score based on transaction velocity (see below) |
| payment_risk_score | Risk score based on payment patterns (see below) |
| address_risk_score | Risk score based on address signals (see below) |
| overall_risk_score | Weighted combination of risk scores, capped at 100 |
| risk_segment | Categorize customer risk (see below) |
| first_transaction_date | From int_transaction_velocity |
| last_transaction_date | From int_transaction_velocity |

## Risk Score (Transaction Level)

Weighted composite score capped at 100:
- High value transaction (>500): 15 points
- New customer (<=2 transactions): 20 points
- Payment failure: 25 points if payment failed
- Customer failure rate: 20 points if customer_failure_rate > 0.3
- Multiple cards: 10 points if customer uses_multiple_cards
- Address mismatch: 15 points if billing != shipping
- Low address verification: 10 points if customer_address_verification_rate < 0.5
- Multiple countries: 10 points if customer has_multiple_countries

Round to 2 decimals. Default 0 for NULL values.

## Review Priority (Transaction Level)

Score based on urgency for manual review:
- Risk score 80+: 100 (immediate review)
- Risk score 70+ with high value: 90
- Risk score 60+ with new customer: 85
- Risk score 50+ with payment failure: 80
- Risk score 50+: 70
- Risk score 40+ with address mismatch: 65
- Risk score 40+: 50
- Risk score 30+: 30
- Otherwise: 10

Round to 2 decimals.

## Transaction Frequency Score (Customer Level)

Normalized score 0-100 based on avg_transactions_per_day:
- >= 5.0 transactions/day: 100 (very high velocity, suspicious)
- >= 2.0 transactions/day: 80
- >= 1.0 transactions/day: 60
- >= 0.5 transactions/day: 40
- >= 0.1 transactions/day: 20
- Otherwise: 10

## Velocity Risk Score (Customer Level)

Score based on transaction patterns:
- transaction_frequency_score >= 80: 40 points
- transaction_frequency_score >= 60: 25 points
- transaction_frequency_score >= 40: 15 points
- high_value_transaction_count > 5: add 20 points
- high_value_transaction_count > 2: add 10 points
- days_as_customer < 7 with total_transactions > 5: add 25 points

Capped at 100, rounded to 2 decimals.

## Payment Risk Score (Customer Level)

Score based on payment behavior:
- payment_failure_rate > 0.5: 50 points
- payment_failure_rate > 0.3: 35 points
- payment_failure_rate > 0.1: 20 points
- uses_multiple_cards = TRUE: add 15 points
- card_diversity_count > 3: add 20 points
- card_diversity_count > 2: add 10 points

Capped at 100, rounded to 2 decimals.

## Address Risk Score (Customer Level)

Score based on address signals:
- address_verification_rate < 0.3: 40 points
- address_verification_rate < 0.5: 25 points
- address_verification_rate < 0.8: 10 points
- has_multiple_countries = TRUE: add 25 points
- billing_shipping_mismatch_rate > 0.5: add 30 points
- billing_shipping_mismatch_rate > 0.2: add 15 points

Capped at 100, rounded to 2 decimals.

## Overall Risk Score (Customer Level)

Weighted combination:
- velocity_risk_score x 0.30
- payment_risk_score x 0.40
- address_risk_score x 0.30

Capped at 100, rounded to 2 decimals.

## Risk Segment (Customer Level)

Categorize customers based on behavior patterns:
- 'HIGH_RISK': overall_risk_score >= 70
- 'WATCH_LIST': overall_risk_score >= 50 AND overall_risk_score < 70
- 'ELEVATED': overall_risk_score >= 30 AND overall_risk_score < 50
- 'TRUSTED': overall_risk_score < 30 AND days_as_customer >= 30 AND payment_failure_rate < 0.1
- 'NEW': days_as_customer < 30 AND overall_risk_score < 30
- 'STANDARD': Otherwise

## Requirements

### transaction_risk_scores
- Only include transactions from last 90 days (relative to the most recent transaction date in the data)
- One row per order_id
- No NULL values in order_id, customer_id, risk_score, risk_tier
- risk_score range: 0-100
- review_priority range: 0-100
- Order by order_date descending

### customer_risk_profile
- Only include customers with transactions from last 90 days (relative to the most recent transaction date in the data)
- One row per customer_id
- No NULL values in customer_id, total_transactions, overall_risk_score, risk_segment
- All risk scores range: 0-100
- risk_segment must be one of: 'HIGH_RISK', 'WATCH_LIST', 'ELEVATED', 'TRUSTED', 'NEW', 'STANDARD'
- Order by overall_risk_score descending, then by customer_id

### int_transaction_velocity
- One row per customer_id
- No NULL values in customer_id, total_transactions

### int_payment_patterns
- One row per customer_id
- No NULL values in customer_id, total_payments, payment_failure_rate

### int_customer_address_risk
- One row per customer_id
- No NULL values in customer_id, total_addresses

## Data Constraints

The test data has the following characteristics:
- Transaction amounts: Range from small purchases to approximately $1,000,000 maximum
- Customer transaction counts: Customers have between 1 and approximately 10,000 transactions in the data

Your implementation should handle the full range of values present in the source data.

## Guidelines

- Use CAST() for type conversions instead of :: syntax
- Use standard date functions that work on both databases
- Handle NULL values appropriately with COALESCE
