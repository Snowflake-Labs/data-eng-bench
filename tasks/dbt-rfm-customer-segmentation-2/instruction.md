# RFM Customer Segmentation with Predictive Analytics

Build an RFM analysis system with churn prediction, cohort retention analysis, and intervention recommendations.

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

## Environment

- **dbt project**:
  - DuckDB: `/app/dbt_models_duckdb`
  - Snowflake: `/app/dbt_models_snowflake`
- **Target schema**: `rfm_analytics` (appears as `main_rfm_analytics` in DuckDB, or `main` in Snowflake if generate_schema_name is overridden)
- **Reference date**: 2025-01-01 (use this for all recency/tenure calculations)

(Important: For Snowflake, you must override the `generate_schema_name` macro so that dbt uses the custom schema name exactly as specified, rather than prepending the target schema. Without this override, models will be created in the wrong schema, e.g. `main_rfm_analytics` instead of `main`. Place the override in `macros/utils/generate_schema_name.sql` -- if this file already exists, overwrite it.)

## Source Data

Use `{{ source('orders', 'ORDERS') }}` to reference the orders table. Explore the table to understand available columns including order identifiers, customer identifiers, timestamps, monetary amounts, and status fields.

Exclude orders with STATUS in ('CANCELLED', 'RETURNED').

---

## Model 1: `rfm_segments`

**Location**: `models/marts/rfm/rfm_segments.sql`

| Column | Description |
|--------|-------------|
| customer_id | Customer identifier |
| first_order_date | Date of first order |
| last_order_date | Date of most recent order |
| customer_tenure_days | Days from first order to reference date |
| recency_days | Days since last order (from reference date) |
| recency_score | 1-5 score using NTILE(5), ordered by recency_days DESC with customer_id as tiebreaker |
| recency_percentile | PERCENT_RANK * 100, rounded to 2 decimals |
| total_orders | Count of valid orders |
| frequency_score | 1-5 NTILE score on total_orders ASC, customer_id as tiebreaker |
| frequency_percentile | PERCENT_RANK * 100, rounded to 2 decimals |
| total_spent | Sum of order amounts |
| monetary_score | 1-5 NTILE score on total_spent ASC, customer_id as tiebreaker |
| monetary_percentile | PERCENT_RANK * 100, rounded to 2 decimals |
| avg_order_value | total_spent / total_orders, rounded to 2 decimals |
| avg_days_between_orders | Average gap between consecutive orders (0 if single order), rounded to 2 decimals |
| orders_q4_2024 | Orders from Oct-Dec 2024 |
| orders_q3_2024 | Orders from Jul-Sep 2024 |
| orders_q2_2024 | Orders from Apr-Jun 2024 |
| orders_q1_2024 | Orders from Jan-Mar 2024 |
| quarterly_trend | Trend classification (see below) |
| spending_velocity | (Q4 spend - Q3 spend) / Q3 spend * 100 (NULL if Q3=0), rounded to 2 decimals |
| rfm_score | Sum of three scores (3-15) |
| rfm_segment | Segment label based on average score |
| churn_probability | Churn risk 0-100 based on RFM scores and trend |
| lifetime_value_estimate | Predicted future value, rounded to 2 decimals, never negative |

**Quarterly Trend Values:**
- `accelerating`: Increasing order frequency (Q4 > Q3 and Q3 >= Q2)
- `decelerating`: Decreasing order frequency (Q4 < Q3 and Q3 <= Q2)
- `churning`: No Q4 orders but had Q3 orders
- `stable`: All other patterns

**Segment Definitions** (based on average of three scores):
- `Champions`: avg >= 4.5
- `Loyal`: avg >= 3.5
- `Potential`: avg >= 2.5
- `At Risk`: avg >= 1.5
- `Lost`: avg < 1.5

**Churn Probability:**
Calculate a 0-100 risk score where lower RFM scores indicate higher risk. For each dimension, compute (5 - score) and multiply by a weight: recency x 15, frequency x 10, monetary x 5. Sum these to get base risk. Then adjust for quarterly trend: churning +30, decelerating +15, stable +0, accelerating -10. Clamp final result to 0-100.

**Lifetime Value:**
Project future value based on monthly spending rate, expected remaining months (Champions: 36, Loyal: 24, Potential: 12, At Risk: 6, Lost: 0), and retention probability (inverse of churn). Result should be 0 for zero-tenure customers and never negative.

---

## Model 2: `rpt_segment_summary`

**Location**: `models/marts/rfm/rpt_segment_summary.sql`

Aggregate statistics per segment. Order by customer_count DESC.

| Column | Description |
|--------|-------------|
| rfm_segment | Segment name |
| customer_count | Number of customers |
| pct_of_total | Percentage of total customers (2 decimals) |
| total_revenue | Sum of total_spent |
| avg_revenue_per_customer | Average total_spent |
| avg_churn_probability | Average churn_probability |
| total_lifetime_value | Sum of lifetime_value_estimate |
| avg_lifetime_value | Average lifetime_value_estimate |
| churning_customers | Count with quarterly_trend = 'churning' |
| accelerating_customers | Count with quarterly_trend = 'accelerating' |

---

## Model 3: `rpt_customer_recommendations`

**Location**: `models/marts/rfm/rpt_customer_recommendations.sql`

Generate intervention recommendations for each customer. Order by priority_score DESC, then customer_id ASC.

| Column | Description |
|--------|-------------|
| customer_id | Customer ID |
| rfm_segment | From rfm_segments |
| rfm_score | From rfm_segments |
| quarterly_trend | From rfm_segments |
| churn_probability | From rfm_segments |
| risk_level | Risk classification |
| intervention_type | Type of action needed |
| recommended_action | Specific action text |
| estimated_value | lifetime_value_estimate from rfm_segments |
| urgency_days | Days until intervention needed |
| priority_score | Outreach priority |

**Risk Level Assignment:**
- `CRITICAL`: churn >= 80, OR (churning trend AND high-value segment like Loyal/Champions)
- `HIGH`: churn >= 60, OR churning trend
- `MEDIUM`: churn >= 40, OR decelerating trend
- `LOW`: all others

**Intervention Type:**
- CRITICAL: `immediate_outreach`
- HIGH: `win_back_campaign`
- MEDIUM: `engagement_program`
- LOW: `loyalty_program`

**Recommended Action** (exact strings required):
| Segment | CRITICAL/HIGH Risk | MEDIUM/LOW Risk |
|---------|-------------------|-----------------|
| Champions | Executive outreach with exclusive preview access | VIP early access and personalized recommendations |
| Loyal | Personal account manager contact with special offer | Loyalty program upgrade with bonus points |
| Potential | Targeted email series with progressive discounts | Targeted email series with progressive discounts |
| At Risk | Urgent win-back: 30% off next purchase within 7 days | Urgent win-back: 30% off next purchase within 7 days |
| Lost | Final reactivation: 50% off or account closure notice | Final reactivation: 50% off or account closure notice |

**Urgency Days:**
- CRITICAL: 3
- HIGH: 7
- MEDIUM: 14
- LOW: 30

**Priority Score:**
Higher priority for higher churn risk, higher RFM value, higher urgency, and more valuable segments. Use weights: churn (2x), rfm_score (5x), urgency bonus (CRITICAL: 100, HIGH: 50, MEDIUM: 25, LOW: 0), segment value (Champions: 50, Loyal: 40, Potential: 30, At Risk: 20, Lost: 10).

---

## Model 4: `rfm_cohort_retention`

**Location**: `models/marts/rfm/rfm_cohort_retention.sql`

Monthly cohort retention analysis. Order by cohort_month ASC, months_since_first ASC.

| Column | Description |
|--------|-------------|
| cohort_month | First order month (YYYY-MM format) |
| months_since_first | 0, 1, 2, ... months after cohort month |
| cohort_size | Original customers in cohort |
| retained_customers | Customers who ordered in this period |
| retention_rate | retained_customers / cohort_size * 100 (2 decimals) |
| cohort_revenue | Total revenue from retained customers in this period |
| avg_order_value | Average order value for this cohort-period |

**Constraints:**
- Only include cohorts from 2024
- Only include periods where the month falls before 2025-01-01
- A customer is "retained" if they placed at least one valid order during that calendar month
- Retention at month 0 should be 100% (all cohort members ordered in their first month by definition)

## Guidelines

- The SQL syntax should work on both DuckDB and Snowflake (ANSI SQL compatible)
- Use `DATEDIFF('day', start, end)` for date arithmetic (works on both backends)
- For date formatting to YYYY-MM strings, use Jinja conditionals: `TO_VARCHAR` for Snowflake, `strftime` for DuckDB
- Use `CAST(... AS DOUBLE)` for division operations to avoid integer division issues
- You can install additional libraries as needed
