# Review Moderation and Trust Risk: dbt Modeling Instructions

## Goal
Build a small dbt model set that supports review moderation and trust-risk analysis. The models must use the existing staging tables and specifically use `stg_orders__orders` and `stg_orders__order_lines` for order data (do not use any other orders header model).

Create three models:
- An intermediate enrichment model that joins reviews to orders, order lines, fraud, returns, coupons, customers, ratings, and event velocity signals.
- A fact model that computes trust scores, risk buckets, and moderation queue priority.
- A KPI rollup model that summarizes moderation trends monthly.

Place these models under:
- DuckDB: `/app/dbt_models_duckdb/models/intermediate/reviews/`
- Snowflake: `/app/dbt_models_snowflake/models/intermediate/reviews/`
- DuckDB: `/app/dbt_models_duckdb/models/marts/reviews/`
- Snowflake: `/app/dbt_models_snowflake/models/marts/reviews/`

Also add schema files in each folder describing the models and tests.

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

## Source Models to Use
Use only existing staging models in the project (no raw sources):
- Reviews: `stg_product__product_reviews`
- Orders header: `stg_orders__orders`
- Order lines: `stg_orders__order_lines`
- Fraud scores: `stg_orders__order_fraud_scores`
- Returns: `stg_orders__returns`
- Return lines: `stg_orders__return_lines`
- Coupons: `stg_coupon_usage`
- Customers: `stg_customer__customers`
- Product rating summary: `stg_product_ratings_summary` (note: **no** double-underscore; do not use `stg_product__product_ratings_summary`)
- Events: `stg_events`

### Allowed Dependencies for int_reviews__enriched
The `int_reviews__enriched` model must only `ref()` these staging models (no others):
- `stg_product__product_reviews`
- `stg_orders__orders`
- `stg_orders__order_lines`
- `stg_orders__order_fraud_scores`
- `stg_orders__returns`
- `stg_orders__return_lines`
- `stg_coupon_usage`
- `stg_customer__customers`
- `stg_product_ratings_summary`
- `stg_events`

## Business Rules (Natural Language)
### Review-to-Order Matching
For each review, select at most one best matching order line. Use the following rules:
1. If `review.order_id` is present, match order lines on `order_id`. If `review.product_id` is also present, the line must match that product.
2. If `review.order_id` is missing, match by `customer_id` and `product_id` instead.
3. Only consider orders where `ordered_at` is on or before the review timestamp.
4. If multiple lines match, rank them by:
   - Exact order_id match first,
   - Most recent `ordered_at`,
   - Lowest line_number.
5. Pick the top-ranked line as the match.

### Required Field Mapping and Join Pattern
To ensure consistent business logic and column names, follow this structure precisely:
- **Reviews CTE**: select only the needed fields from `stg_product__product_reviews` and alias `status` to `review_status`. Also compute `review_ts` and `review_date` inside this CTE.
- **Orders CTE**: select only the needed fields from `stg_orders__orders` and alias:
  - `customer_id` -> `order_customer_id`
  - `status` -> `order_status`
- **Order Lines CTE**: select only the needed fields from `stg_orders__order_lines` and alias:
  - `quantity` (if present) should **not** be used; use `quantity_ordered`
  - `status` -> `line_status`
- **Order Lines + Orders CTE**: join order lines to orders into a single CTE (often called `order_lines_orders`) so each line carries order-level fields and the order's customer id. This is the table used for matching reviews to lines.

### Review <-> Order Line Matching Implementation Details
Implement the matching logic with:
- An **inner join** from reviews to the `order_lines_orders` CTE, with the order/date constraints in the **join condition** (not a `where` filter).
- The date constraint must be `ol.ordered_at <= r.review_ts OR r.review_ts is null`.
- Rank with `row_number()` over `review_id`, ordering by:
  1) exact order_id match (order_id present and equal) first,
  2) most recent `ordered_at` (desc, nulls last),
  3) lowest `line_number`.
- Select only the top-ranked row as `best_line`.

### Reviews With Orders (Coalescing)
Build a `reviews_with_orders` CTE that:
- Keeps all reviews (left join to `best_line`),
- Uses `coalesce` to backfill order fields from `best_line` when present, otherwise from `orders` using the review's `order_id`,
- Produces `matched_order_id` and `matched_customer_id` using `coalesce` of line match and review/customer.

### Fraud, Returns, and Coupons (Exact Aggregation Rules)
- **Fraud scores**: from `stg_orders__order_fraud_scores`, map:
  - `score` -> `fraud_score_value`
  - `risk_level` -> `fraud_risk_level`
  - `provider` -> `fraud_provider`
  - `reviewed_by` -> `fraud_reviewed_by`
  - `reviewed_at` -> `fraud_reviewed_at`
- **Returns**:
  - Use `stg_orders__returns` with `status` aliased to `return_status`.
  - Build `return_lines_enriched` by joining return lines to order lines to obtain `order_id` and `product_id`.
  - Aggregate `returns_by_order` with `count(distinct return_id)` and `sum(refund_amount)`.
  - Aggregate `returns_by_order_product` with:
    - `sum(quantity_returned)` as `product_return_qty`
    - `count(distinct return_line_id)` as `product_return_line_count`
    - `sum(return_line_refund)` as `product_return_refund`
- **Coupons**:
  - Use `stg_coupon_usage` (not a POS-specific variant).
  - Aggregate with `count(distinct redemption_id)` and `sum(try_cast(discount_amount as double))` as `coupon_discount_total`.

### Review Timestamp
- Define `review_ts` as `submitted_at` when present; otherwise use `created_at`.
- Define `review_date` as the date portion of `review_ts`.

### Returns and Coupons
- Aggregate returns by order (count of returns, sum refund_amount, and latest return status).
- Aggregate return lines by order and product (returned quantity, count of return lines, and refund amount).
- Aggregate coupon usage by order (count of redemption_id and sum of discount_amount). Ensure discount_amount is treated as numeric.

### Event Velocity Signals
- For events, parse event timestamp as timestamp when possible; otherwise use created_at as timestamp.
- In the int model `events` CTE, cast `created_at` to timestamp explicitly.
- Aggregate events by product and day.
- For each review, compute a 7-day product event count from review_date minus 7 days through review_date.
- Also compute review velocity as counts of reviews per product per day and per customer per day.

### Trust Risk Scoring
Create boolean flags (all flags must be explicit `true/false` with `CASE` and an `else false` to avoid NULLs from three-valued logic):
- `rating_outlier_flag`: true when product average rating exists **and** the review rating differs by 2 or more points; otherwise false (including when rating is null).
- `coupon_used_flag`: true when coupon_redemption_count > 0 (treat null as 0), else false.
- `return_flag`: true when product_return_qty > 0 OR return_count > 0 (treat null as 0), else false.
- `fraud_high_flag`: true when fraud risk level is HIGH/CRITICAL OR fraud_check_status is FAIL; otherwise false (including when both are null).
- `unverified_purchase_flag`: true when is_verified_purchase is not true; otherwise false.
- `customer_velocity_flag`: true when customer_review_count_day >= 3 (treat null as 0), else false.
- `product_velocity_flag`: true when product_review_count_day >= 20 (treat null as 0), else false.
- `low_content_flag`: true when review_text is null or shorter than 20 characters; otherwise false.

Compute these additional metrics:
- `review_text_length` = length of review_text.
- `time_to_review_days` = days between ordered_at and review_ts using `DATEDIFF('day', ordered_at, review_ts)`.
- `moderation_latency_hours` = hours between review_ts and moderated_at using `DATEDIFF('hour', review_ts, moderated_at)`.
- `rating_delta` = review rating minus product average rating.

### Trust Score Calculation
Compute a deduction score as the sum of the following penalties:
- 30 if unverified_purchase_flag
- 20 if fraud_high_flag
- 10 if coupon_used_flag
- 10 if return_flag
- 5 if email_verified is false
- 5 if phone_verified is false
- 5 if low_content_flag
- 5 if rating_outlier_flag
- 5 if customer_velocity_flag
- 5 if product_velocity_flag
- 5 if time_to_review_days is not null and time_to_review_days < 1
- 5 if time_to_review_days is not null and time_to_review_days > 365

Then:
- Compute `score_deductions` and `trust_score` in the same CTE (e.g., `scored_with_score`).
- `trust_score` must be calculated by repeating the full penalty expression inside `greatest(0, 100 - (...))` rather than referencing `score_deductions`.
- `risk_bucket` is HIGH if trust_score < 50, MEDIUM if < 80, else LOW (use the `trust_score` column, do not recompute the expression).
- `queue_priority` is P1 if fraud_high_flag OR unverified_purchase_flag OR coupon_used_flag. Otherwise P2 if rating_outlier_flag OR customer_velocity_flag OR product_velocity_flag. Otherwise P3.

### KPI Rollup
Group by review month, channel_id, review_source, fraud_risk_level, risk_bucket, and rejection_reason (use 'NONE' when null). Produce:
- Total reviews
- Verified review count and verified purchase share (percentage)
- Average time_to_review_days
- Average moderation latency hours
- Count of rating_outlier_flag
- Average absolute rating_delta
- Counts of product_velocity_flag and customer_velocity_flag
- Counts of reviews with returns and reviews with coupons
- Average trust_score

**KPI calculation details:**
- Use `date_trunc('month', review_date)` for `review_month`.
- `verified_review_count` should be `sum(case when is_verified_purchase then 1 else 0 end)`.
- `verified_purchase_share` must be:
  - `round(100.0 * verified_review_count / nullif(count(*), 0), 2)`
  - Do not use an explicit `case when count(*) > 0` fallback; use `nullif` and `round` as shown.

## Required Models and Files
### 1) Intermediate model
Create `int_reviews__enriched` in `models/intermediate/reviews/`.
- Materialization: view
- Tags: intermediate, reviews, trust-risk
- Business logic: perform the joins and calculations described above.

### 2) Fact model
Create `fct_review_moderation_risk` in `models/marts/reviews/`.
- Materialization: view
- Tags: marts, reviews, trust-risk
- Business logic: add scoring, risk buckets, and queue priority.

### 3) KPI rollup
Create `rpt_review_moderation_kpis` in `models/marts/reviews/`.
- Materialization: view
- Tags: marts, reviews, trust-risk
- Business logic: monthly KPI aggregation described above.

### 4) Schema files
Add schema files with descriptions and tests:
- `models/intermediate/reviews/schema.yml`
  - Include `int_reviews__enriched` and a not_null test on review_id.
- `models/marts/reviews/schema.yml`
  - Include `fct_review_moderation_risk` with not_null + unique tests on review_id.
  - Include `rpt_review_moderation_kpis` with descriptive columns.

## Exact Output Schemas
List columns in the exact order shown below.

### int_reviews__enriched
| Column | Type |
| --- | --- |
| review_id | string |
| product_id | string |
| variant_id | string |
| customer_id | string |
| matched_customer_id | string |
| order_id | string |
| order_line_id | string |
| rating | numeric |
| review_title | string |
| review_text | string |
| pros | string |
| cons | string |
| is_verified_purchase | boolean |
| is_recommended | boolean |
| helpful_count | integer |
| not_helpful_count | integer |
| review_status | string |
| moderated_at | timestamp |
| moderated_by | string |
| rejection_reason | string |
| review_source | string |
| reviewer_display_name | string |
| submitted_at | timestamp |
| created_at | timestamp |
| updated_at | timestamp |
| review_ts | timestamp |
| review_date | date |
| channel_id | string |
| order_source | string |
| order_type | string |
| order_status | string |
| payment_status | string |
| fulfillment_status | string |
| ordered_at | timestamp |
| shipped_at | timestamp |
| delivered_at | timestamp |
| cancelled_at | timestamp |
| fraud_score | numeric |
| fraud_check_status | string |
| quantity_ordered | numeric |
| line_quantity_returned | numeric |
| line_unit_price | numeric |
| line_discount_amount | numeric |
| line_tax_amount | numeric |
| line_total | numeric |
| line_status | string |
| fraud_score_value | numeric |
| fraud_risk_level | string |
| fraud_provider | string |
| fraud_reviewed_by | string |
| fraud_reviewed_at | timestamp |
| return_count | integer |
| total_refund_amount | numeric |
| latest_return_status | string |
| product_return_qty | numeric |
| product_return_line_count | integer |
| product_return_refund | numeric |
| coupon_redemption_count | integer |
| coupon_discount_total | numeric |
| email_verified | boolean |
| phone_verified | boolean |
| customer_status | string |
| churn_risk_tier | string |
| segment_ml | string |
| first_order_date | date |
| last_order_date | date |
| total_orders | integer |
| total_lifetime_value | numeric |
| current_tier_id | string |
| product_total_reviews | integer |
| product_average_rating | numeric |
| rating_1_count | integer |
| rating_2_count | integer |
| rating_3_count | integer |
| rating_4_count | integer |
| rating_5_count | integer |
| recommend_percentage | numeric |
| product_last_review_date | date |
| product_event_7d_count | integer |
| product_review_count_day | integer |
| customer_review_count_day | integer |

### fct_review_moderation_risk
Includes all columns from `int_reviews__enriched` in the same order, followed by:

| Column | Type |
| --- | --- |
| review_text_length | integer |
| time_to_review_days | integer |
| moderation_latency_hours | integer |
| rating_delta | numeric |
| rating_outlier_flag | boolean |
| coupon_used_flag | boolean |
| return_flag | boolean |
| fraud_high_flag | boolean |
| unverified_purchase_flag | boolean |
| customer_velocity_flag | boolean |
| product_velocity_flag | boolean |
| low_content_flag | boolean |
| score_deductions | integer |
| trust_score | integer |
| risk_bucket | string |
| queue_priority | string |

### rpt_review_moderation_kpis
| Column | Type |
| --- | --- |
| review_month | timestamp |
| channel_id | string |
| review_source | string |
| fraud_risk_level | string |
| risk_bucket | string |
| rejection_reason | string |
| review_count | integer |
| verified_review_count | integer |
| verified_purchase_share | numeric |
| avg_time_to_review_days | numeric |
| avg_moderation_latency_hours | numeric |
| rating_outlier_count | integer |
| avg_rating_delta | numeric |
| product_velocity_flag_count | integer |
| customer_velocity_flag_count | integer |
| reviews_with_returns | integer |
| reviews_with_coupons | integer |
| avg_trust_score | numeric |


**Closing Notes:**
- Ignore warnings.
- Mark the task for completion only after validating a successful `dbt run` for the three newly added models.

## Guidelines

- The SQL syntax should work on both DuckDB and Snowflake (ANSI SQL compatible)
- Use `DATEDIFF` instead of `date_diff` for date difference calculations
- For interval arithmetic, use `DATEADD` instead of `interval` expressions where possible
- Handle boolean columns carefully as Snowflake may store them as VARCHAR
