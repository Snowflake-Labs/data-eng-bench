# Product Affinity Analysis (Market Basket Analysis)

Build a comprehensive product affinity analytics suite that identifies products frequently purchased together using association rule mining. This includes calculating support, confidence, lift, and advanced metrics for product pairs, analyzing temporal trends, segmenting by customer type, tracking sequential purchase patterns, and generating category-level affinity insights.

## Environment

- **Analysis date**: December 1, 2024
- **Analysis period**: January 1, 2023 through November 30, 2024

## Files

- DuckDB dbt project: `/app/dbt_models_duckdb/`
- Snowflake dbt project: `/app/dbt_models_snowflake/`

## Source Data

The staging layer provides:

- `stg_orders__orders`: order_id, customer_id, ordered_at, grand_total, status, test_order_flag, is_first_order
- `stg_orders__order_lines`: order_line_id, order_id, product_id, product_name, quantity_ordered, line_total, status
- `stg_product__products`: product_id, product_name, primary_category_id

## Requirements

### Data Rules

Only include orders that are:
- Status is not CANCELLED, RETURNED, or FAILED
- Not a test order (test_order_flag is not 1 or true)
- Within the analysis period (ordered_at >= '2023-01-01' and ordered_at < '2024-12-01')

Only include order lines where:
- status is not CANCELLED or RETURNED
- quantity_ordered > 0

Only include orders with at least 2 distinct products (single-product orders cannot form pairs).

### Models to Create

Create these dbt models:

1. **Intermediate models** in `models/intermediate/`:

   - `int_affinity_order_products`: One row per product per qualifying order. Each row contains the order_id, customer_id, product_id, product_name, ordered_at, is_first_order flag, and the total revenue for that product within that order (sum of line_total, named `product_order_revenue`). These fields are needed downstream for pair revenue, customer segmentation, and temporal analysis.

   - `int_affinity_product_stats`: Aggregated statistics for each product across all qualifying orders. Include the product's total order count and total revenue, plus the overall count of qualifying orders (needed for support calculations).

   - `int_affinity_product_pairs`: Co-occurrence data for each product pair. Generate pairs using a self-join on order_id, ensuring product_a_id < product_b_id to avoid duplicates. Include the co-purchase count, combined pair revenue, and average basket value for orders containing both products.

2. **Mart models** in `models/marts/analytics/`:
   - `product_affinity`: Product pair metrics with association rules (table)
   - `product_affinity_summary`: Top affinities per product (table)
   - `category_affinity`: Category-level co-purchase patterns (table)
   - `affinity_trends`: Monthly co-purchase trends per product pair (table)

### Association Rule Metrics

For each product pair (A, B) where A and B appear together in orders:

**Basic Counts:**
- **co_purchase_count**: Number of orders containing both product A and product B
- **product_a_orders**: Number of orders containing product A (regardless of B)
- **product_b_orders**: Number of orders containing product B (regardless of A)
- **total_orders**: Total number of qualifying orders with 2+ products

**Core Association Metrics:**

1. **support**: Probability that both A and B appear together
   ```
   support = co_purchase_count / total_orders
   ```

2. **confidence_a_to_b**: Probability of B given A (if you buy A, how likely to buy B)
   ```
   confidence_a_to_b = co_purchase_count / product_a_orders
   ```

3. **confidence_b_to_a**: Probability of A given B (if you buy B, how likely to buy A)
   ```
   confidence_b_to_a = co_purchase_count / product_b_orders
   ```

4. **lift**: How much more likely A and B are bought together vs. independently
   ```
   lift = (co_purchase_count * total_orders) / (product_a_orders * product_b_orders)
   ```

5. **conviction_a_to_b**: Measures the implication strength of the rule A -> B
   ```
   conviction_a_to_b = (1 - (product_b_orders / total_orders)) / (1 - confidence_a_to_b)
   ```
   Handle edge case: If confidence_a_to_b >= 1.0, set conviction to 999.99.

6. **conviction_b_to_a**: Measures the implication strength of the rule B -> A
   ```
   conviction_b_to_a = (1 - (product_a_orders / total_orders)) / (1 - confidence_b_to_a)
   ```
   Handle edge case: If confidence_b_to_a >= 1.0, set conviction to 999.99.

**Advanced Association Metrics:**

7. **kulczynski**: The average of both confidence values, providing a symmetric measure
   ```
   kulczynski = (confidence_a_to_b + confidence_b_to_a) / 2
   ```

8. **imbalance_ratio**: Measures the asymmetry between the two confidence directions. Ranges from 0 (perfectly symmetric) to 1 (completely one-sided).
   ```
   imbalance_ratio = |confidence_a_to_b - confidence_b_to_a| / (confidence_a_to_b + confidence_b_to_a)
   ```
   If both confidences are 0, set imbalance_ratio to 0.

9. **jaccard**: The Jaccard similarity coefficient, measuring overlap relative to union
   ```
   jaccard = co_purchase_count / (product_a_orders + product_b_orders - co_purchase_count)
   ```

**Rounding Rules:**
- Round support to 6 decimal places
- Round confidence, kulczynski, imbalance_ratio, and jaccard to 4 decimal places
- Round lift and conviction to 4 decimal places
- Round revenue values to 2 decimal places
- Round percentages to 1 decimal place

### Pair Generation Rules

**Critical**: To avoid duplicate pairs (A,B) and (B,A), enforce ordering:
- Always ensure `product_a_id < product_b_id` (lexicographic comparison)
- This means each pair appears exactly once

**Minimum Thresholds** (to reduce noise):
- Only include pairs where `co_purchase_count >= 3`
- Only include pairs where `support >= 0.0001` (0.01%)

### Affinity Classification

Based on lift values, classify the relationship:

| Classification | Lift Range |
|----------------|------------|
| Strong Positive | lift >= 3.0 |
| Moderate Positive | lift >= 1.5 and < 3.0 |
| Weak Positive | lift > 1.0 and < 1.5 |
| Independent | lift = 1.0 (within 0.01 tolerance) |
| Negative | lift < 1.0 |

### Revenue Impact Analysis

For each product pair, calculate:
- **pair_revenue**: Sum of (line_total for product A + line_total for product B) across all co-purchase orders
- **avg_pair_basket_value**: Average grand_total of orders containing both products
- **pair_revenue_contribution_pct**: pair_revenue as percentage of total revenue from all qualifying orders

### Directionality Analysis

Since confidence is directional, identify which direction is stronger:
- **stronger_direction**: 'A_to_B' if confidence_a_to_b > confidence_b_to_a, else 'B_to_A', else 'Equal'
- **confidence_ratio**: max(confidence_a_to_b, confidence_b_to_a) / min(confidence_a_to_b, confidence_b_to_a)
  - Set to 1.0 if both confidences are equal
  - Set to 999.99 if min confidence is 0

### Temporal Trend Analysis

Analyze how pair affinity changes over time by comparing two periods:
- **Period 1 (Early)**: January 1, 2023 through December 31, 2023
- **Period 2 (Recent)**: January 1, 2024 through November 30, 2024

For each pair, calculate:
- **early_co_purchase_count**: Co-purchases in Period 1
- **recent_co_purchase_count**: Co-purchases in Period 2
- **early_lift**: Lift calculated using only Period 1 data
- **recent_lift**: Lift calculated using only Period 2 data

**Trend Classification** based on comparing recent vs early lift:
- `Strengthening`: recent_lift > early_lift x 1.2 (more than 20% increase)
- `Weakening`: recent_lift < early_lift x 0.8 (more than 20% decrease)
- `Stable`: otherwise
- `New`: early_co_purchase_count = 0 (pair didn't exist in early period)
- `Discontinued`: recent_co_purchase_count = 0 (pair stopped in recent period)

If early_lift cannot be calculated (insufficient data), use co_purchase_count comparison instead.

### Customer Segmentation Analysis

Analyze affinity patterns by customer type using the is_first_order flag:
- **first_time_co_purchases**: Co-purchase count from orders where is_first_order = 1 or true
- **repeat_co_purchases**: Co-purchase count from orders where is_first_order = 0, false, or null

Calculate:
- **first_time_pct**: Percentage of co-purchases from first-time buyers (first_time_co_purchases / co_purchase_count x 100)

**Customer Affinity Segment** (based on first_time_pct):
- `First-Time Favorite`: first_time_pct >= 60%
- `Repeat Favorite`: first_time_pct <= 40% (i.e., repeat buyers account for >= 60%)
- `Universal`: first_time_pct between 40% and 60% (neither segment dominates)

### Sequential Purchase Analysis

For customers who have purchased both products A and B across different orders (not in the same order), analyze the purchase sequence:

- **sequential_customers**: Count of customers who bought both A and B in separate orders
- **a_first_count**: How many of those customers bought A before B (based on ordered_at)
- **b_first_count**: How many bought B before A
- **same_day_count**: How many bought both on the same day (in different orders)

- **a_first_pct**: Percentage where A was purchased first (a_first_count / sequential_customers x 100)
- **avg_days_a_to_b**: Average days between buying A first and then B (only for a_first customers)
- **avg_days_b_to_a**: Average days between buying B first and then A (only for b_first customers)

**Lead Product** (based on a_first_count and b_first_count relative to sequential_customers):
- 'Product A Leads' if a_first_pct > 60%
- 'Product B Leads' if (b_first_count / sequential_customers x 100) > 60%
- 'No Clear Leader' otherwise

If sequential_customers < 3, set lead_product to 'Insufficient Data' and avg_days fields to NULL.

## Output: product_affinity

| Column | Type | Description |
|--------|------|-------------|
| product_a_id | string | First product ID (lexicographically smaller) |
| product_a_name | string | First product name |
| product_b_id | string | Second product ID (lexicographically larger) |
| product_b_name | string | Second product name |
| co_purchase_count | integer | Orders containing both products |
| product_a_orders | integer | Orders containing product A |
| product_b_orders | integer | Orders containing product B |
| total_orders | integer | Total qualifying orders |
| support | decimal(6) | P(A and B) |
| confidence_a_to_b | decimal(4) | P(B given A) |
| confidence_b_to_a | decimal(4) | P(A given B) |
| lift | decimal(4) | Association strength |
| conviction_a_to_b | decimal(4) | Implication strength A -> B |
| conviction_b_to_a | decimal(4) | Implication strength B -> A |
| kulczynski | decimal(4) | Average of both confidences |
| imbalance_ratio | decimal(4) | Confidence asymmetry (0-1) |
| jaccard | decimal(4) | Jaccard similarity coefficient |
| affinity_class | string | Strong Positive/Moderate Positive/Weak Positive/Independent/Negative |
| stronger_direction | string | A_to_B/B_to_A/Equal |
| confidence_ratio | decimal(4) | Confidence asymmetry measure |
| pair_revenue | decimal(2) | Combined revenue from pair |
| avg_pair_basket_value | decimal(2) | Avg order value when pair purchased |
| pair_revenue_contribution_pct | decimal(1) | Percent of total revenue |
| pair_rank | integer | Rank by co_purchase_count (1 = most frequent) |
| early_co_purchase_count | integer | Co-purchases in 2023 |
| recent_co_purchase_count | integer | Co-purchases in 2024 |
| trend_classification | string | Strengthening/Weakening/Stable/New/Discontinued |
| first_time_co_purchases | integer | Co-purchases from first-time buyers |
| repeat_co_purchases | integer | Co-purchases from repeat buyers |
| first_time_pct | decimal(1) | Percent from first-time buyers |
| customer_affinity_segment | string | First-Time Favorite/Repeat Favorite/Universal |
| sequential_customers | integer | Customers who bought both in separate orders |
| a_first_count | integer | Customers who bought A first |
| b_first_count | integer | Customers who bought B first |
| a_first_pct | decimal(1) | Percent who bought A first |
| avg_days_a_to_b | decimal(1) | Avg days from A to B purchase |
| avg_days_b_to_a | decimal(1) | Avg days from B to A purchase |
| lead_product | string | Product A Leads/Product B Leads/No Clear Leader/Insufficient Data |

No NULL values except avg_days_a_to_b and avg_days_b_to_a when sequential_customers < 3.
Order by co_purchase_count DESC, product_a_id ASC, product_b_id ASC.

## Output: product_affinity_summary

For each product, show its top 5 most frequently co-purchased products.

| Column | Type | Description |
|--------|------|-------------|
| product_id | string | The focal product |
| product_name | string | Focal product name |
| product_total_orders | integer | Total orders containing this product |
| product_total_revenue | decimal(2) | Total revenue from this product |
| rank | integer | Rank of associated product (1-5) |
| associated_product_id | string | The co-purchased product |
| associated_product_name | string | Associated product name |
| co_purchase_count | integer | Times purchased together |
| confidence | decimal(4) | P(associated given focal) |
| lift | decimal(4) | Lift for this pair |
| trend_classification | string | Trend for this pair |
| customer_affinity_segment | string | Customer segment for this pair |

Only include products that appear in at least 10 orders. Order by product_id, rank.

## Output: category_affinity

Aggregate affinity metrics at the category level.

| Column | Type | Description |
|--------|------|-------------|
| category_a_id | string | First category (lexicographically smaller) |
| category_b_id | string | Second category (lexicographically larger) |
| co_purchase_count | integer | Orders with products from both categories |
| category_a_orders | integer | Orders with any product from category A |
| category_b_orders | integer | Orders with any product from category B |
| support | decimal(6) | P(cat A and cat B) |
| confidence_a_to_b | decimal(4) | P(cat B given cat A) |
| confidence_b_to_a | decimal(4) | P(cat A given cat B) |
| lift | decimal(4) | Category association strength |
| kulczynski | decimal(4) | Average of both confidences |
| jaccard | decimal(4) | Jaccard similarity |
| affinity_class | string | Classification based on lift |
| avg_products_per_pair_order | decimal(2) | Average distinct products in orders with both categories |
| pair_revenue | decimal(2) | Revenue from orders containing both categories |
| unique_product_pairs | integer | Number of distinct product pairs spanning these categories |

Exclude self-pairs (category_a_id = category_b_id). Order by co_purchase_count DESC.

## Output: affinity_trends

Monthly breakdown of co-purchase patterns for product pairs that meet the minimum thresholds.

| Column | Type | Description |
|--------|------|-------------|
| product_a_id | string | First product ID |
| product_b_id | string | Second product ID |
| order_month | string | Month in format "YYYY-MM" |
| monthly_co_purchases | integer | Co-purchases in this month |
| monthly_pair_revenue | decimal(2) | Pair revenue in this month |
| cumulative_co_purchases | integer | Running total of co-purchases up to this month |
| cumulative_pair_revenue | decimal(2) | Running total of pair revenue up to this month |
| month_rank | integer | Rank of this month for this pair (1 = first month with co-purchases) |
| pct_of_total_co_purchases | decimal(1) | This month's co-purchases as percent of pair's total |
| monthly_first_time_pct | decimal(1) | Percent of this month's co-purchases from first-time buyers |

Only include months where the pair had at least 1 co-purchase.
Order by product_a_id, product_b_id, order_month.

## Materialization

- Intermediate models: views
- `product_affinity`: table
- `product_affinity_summary`: table
- `category_affinity`: table
- `affinity_trends`: table

## Verification

```bash
# For DuckDB
cd /app/dbt_models_duckdb
dbt run --select +product_affinity +product_affinity_summary +category_affinity +affinity_trends

# For Snowflake
cd /app/dbt_models_snowflake
dbt run --select +product_affinity +product_affinity_summary +category_affinity +affinity_trends
```

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

## Guidelines

- The SQL syntax should work on both DuckDB and Snowflake (ANSI SQL compatible)
- Do NOT modify upstream staging models
- Do NOT change model materialization
