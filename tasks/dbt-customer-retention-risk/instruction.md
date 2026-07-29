# Build Customer Retention Risk Analysis Model

## Overview

Create a new dbt model from scratch that analyzes customer ordering behavior to identify retention risk. The model calculates RFM-style metrics (Recency, Frequency, Monetary) and classifies customers into risk tiers for proactive engagement.

## Files

- DuckDB: `/app/dbt_models_duckdb/models/marts/customer/rpt_customer_retention_risk.sql`
- Snowflake: `/app/dbt_models_snowflake/models/marts/customer/rpt_customer_retention_risk.sql`

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

Use these tables — explore each to discover available columns:

- `int_sales__orders_enriched` — Order data with identifiers, financial totals, timestamps, and status information.
- `stg_customer__customers` — Customer master data with profile attributes and categorization fields.
- `stg_orders__returns` — Return records with identifiers, customer linkage, and refund amounts.

### Reference Date

Use `MAX(ordered_at)` from the orders table as the reference date for all time-based calculations. Do NOT use `current_date`.

### Customer Filtering

- Only include customers with `customer_id IS NOT NULL`
- Only include customers that have at least 1 order in `int_sales__orders_enriched`
- Exclude orders with status `'CANCELLED'`

### Base Metrics (per customer)

Calculate these metrics for each customer:

| Metric                | Description                                      |
| --------------------- | ------------------------------------------------ |
| total_orders          | Count of non-cancelled orders                    |
| total_revenue         | Sum of grand_total from non-cancelled orders     |
| first_order_date      | Earliest ordered_at timestamp                    |
| last_order_date       | Most recent ordered_at timestamp                 |
| days_since_last_order | Days between last_order_date and reference date  |
| customer_tenure_days  | Days between first_order_date and reference date |
| total_returns         | Count of returns for this customer               |
| total_refund_amount   | Sum of REFUND_AMOUNT for this customer           |

### Calculated Metrics

| Metric             | Formula                                      | Notes                   |
| ------------------ | -------------------------------------------- | ----------------------- |
| avg_order_value    | total_revenue / total_orders                 | Handle division by zero |
| order_frequency    | total_orders / (customer_tenure_days / 30.0) | Orders per 30 days      |
| net_revenue        | total_revenue - total_refund_amount          |                         |
| return_rate        | total_returns / total_orders                 | Handle division by zero |
| revenue_per_tenure | net_revenue / (customer_tenure_days / 365.0) | Annualized revenue      |

### Retention Risk Score

Calculate a composite `retention_risk_score` (0-100 scale, where 100 = highest risk) using these exact formulas:

**Step 1: Calculate overall medians across all customers**

- `median_aov` = MEDIAN(avg_order_value) across all customers
- `median_freq` = MEDIAN(order_frequency) across all customers

**Step 2: Calculate individual risk factors (each normalized to 0-1 scale)**

| Factor         | Formula (0-1 scale)                                                      | Weight |
| -------------- | ------------------------------------------------------------------------ | ------ |
| recency_risk   | `MIN(days_since_last_order / 90, 1)` (capped at 1)                     | 40%    |
| frequency_risk | `1 - MIN(order_frequency / median_freq, 2) / 2` (capped at 0-1)        | 25%    |
| monetary_risk  | `1 - MIN(avg_order_value / median_aov, 2) / 2` (capped at 0-1)         | 20%    |
| return_risk    | `MIN(return_rate / 0.30, 1)` (0.30 = max acceptable rate, capped at 1) | 15%    |

**Step 3: Calculate final score**

```
retention_risk_score = (
    recency_risk * 0.40 +
    frequency_risk * 0.25 +
    monetary_risk * 0.20 +
    return_risk * 0.15
) * 100
```

The score should be bounded 0-100

**Rationale**:

- Recency: Days since last order over 90 is concerning
- Frequency: Less than half median frequency is risky; more than 2x median gets best score
- Monetary: Less than half median AOV is risky; more than 2x median gets best score
- Returns: Return rates above 30% are critical

### Percentile Metrics

Calculate these rankings :

| Metric               | Description                              | Sort Direction |
| -------------------- | ---------------------------------------- | -------------- |
| recency_percentile   | Percentile rank by days_since_last_order | ASC            |
| frequency_percentile | Percentile rank by order_frequency       | DESC           |
| monetary_percentile  | Percentile rank by avg_order_value       | DESC           |
| risk_percentile      | Percentile rank by retention_risk_score  | ASC            |

**Note**: Sort directions ensure higher percentiles represent "better" customers for frequency/monetary, and "worse" for recency/risk.

### Customer Type Peer Comparison

Add metrics comparing each customer to peers within the same `customer_type`:

| Column                   | Description                                                                   | Calculation Hint                   |
| ------------------------ | ----------------------------------------------------------------------------- | ---------------------------------- |
| type_rank                | Rank within customer_type by retention_risk_score (lowest risk = rank 1)      | Use `PARTITION BY customer_type` |
| type_customer_count      | Total customers in the same customer_type                                     | COUNT over partition               |
| above_type_avg_frequency | 1 if customer's order_frequency > AVG(order_frequency) for their type, else 0 | Compare to window AVG              |


### Retention Risk Tier Classification

Assign a `retention_risk_tier` using **waterfall classification** (check in order, first match wins):

| Tier            | Criteria                                                                        |
| --------------- | ------------------------------------------------------------------------------- |
| churned         | days_since_last_order > 180 AND total_orders = 1                                |
| critical        | risk_percentile >= 0.85 AND days_since_last_order > 90                          |
| at_risk         | risk_percentile >= 0.70 OR (days_since_last_order > 60 AND return_rate >= 0.20) |
| needs_attention | risk_percentile >= 0.50 AND order_frequency < 0.5                               |
| loyal           | risk_percentile <= 0.20 AND order_frequency >= 1.0 AND return_rate < 0.10       |
| stable          | Default fallback                                                                |

**NULL Handling**: Treat NULL days_since_last_order as 999 (worst case). Treat NULL return_rate as 0 (best case). Treat NULL order_frequency as 0 (worst case).

### Customer Health Index

Calculate a `customer_health_index` (0-100, where 100 = healthiest) that inverts the risk perspective.

**Step 1: Calculate medians for normalization**

- `type_median_freq` = MEDIAN(order_frequency) partitioned by customer_type
- `median_net_revenue` = MEDIAN(net_revenue) across all customers

**Step 2: Calculate individual health factors (each normalized to 0-1 scale)**

| Factor     | Formula (0-1 scale)                                                    | Weight |
| ---------- | ---------------------------------------------------------------------- | ------ |
| engagement | `1 - MIN(days_since_last_order / 90, 1)` (inverse of recency risk)   | 35%    |
| loyalty    | `MIN(order_frequency / type_median_freq, 2) / 2` (vs peers, capped)  | 25%    |
| value      | `MIN(net_revenue / median_net_revenue, 3) / 3` (capped at 3x median) | 25%    |
| quality    | `1 - MIN(return_rate / 0.20, 1)` (0.20 = acceptable threshold)       | 15%    |

**Step 3: Calculate final index**

```
customer_health_index = (
    engagement * 0.35 +
    loyalty * 0.25 +
    value * 0.25 +
    quality * 0.15
) * 100
```

The index should be bounded 0-100

**Rationale**:

- Engagement: Recent activity (< 90 days) indicates healthy engagement
- Loyalty: Frequency relative to customer_type peers (up to 2x median gets full score)
- Value: Net revenue contribution (up to 3x median gets full score)
- Quality: Low return rates (< 20%) indicate satisfied customers

## Expected Output

The model must produce these columns:

| Column                   | Type      |
| ------------------------ | --------- |
| customer_id              | varchar   |
| customer_type            | varchar   |
| acquisition_source       | varchar   |
| total_orders             | integer   |
| total_revenue            | decimal   |
| first_order_date         | timestamp |
| last_order_date          | timestamp |
| days_since_last_order    | integer   |
| customer_tenure_days     | integer   |
| total_returns            | integer   |
| total_refund_amount      | decimal   |
| avg_order_value          | decimal   |
| order_frequency          | decimal   |
| net_revenue              | decimal   |
| return_rate              | decimal   |
| revenue_per_tenure       | decimal   |
| retention_risk_score     | decimal   |
| recency_percentile       | decimal   |
| frequency_percentile     | decimal   |
| monetary_percentile      | decimal   |
| risk_percentile          | decimal   |
| type_rank                | integer   |
| type_customer_count      | integer   |
| above_type_avg_frequency | integer   |
| retention_risk_tier      | varchar   |
| customer_health_index    | decimal   |

## Guidelines

- Do NOT modify upstream staging models
- Do NOT change model materialization
- Preserve all output columns
- The SQL syntax should work on both DuckDB and Snowflake (ANSI SQL compatible)
