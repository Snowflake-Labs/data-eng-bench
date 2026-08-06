# Basket Composition Analysis

Build dbt models that analyze order basket composition, including the number of items per order, basket value distribution, customer shopping patterns, half-based trend analysis, and compute composite basket efficiency and growth potential scores.

## Data Environment

- DuckDB: `/app/dbt_transforms` (existing project - add your models here)
- Snowflake: `/app/dbt_models_snowflake` (existing project - add your models here)
- **Analysis period**: Full year 2024 (January 1, 2024 to December 31, 2024)
- **Target schema**: `basket_analytics` (will appear as `main_basket_analytics` in database)

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

## Project Setup
You will add models to the existing dbt project. The project is already configured with:
- Profile pointing to the DuckDB database
- Source definitions for `enterprise_db` schema

**Important**:
- Run `dbt deps` before `dbt run` to install dependencies
- Use `{{ source('enterprise_db', 'TABLE_NAME') }}` syntax to reference source tables
- Set the schema in your model configs or use the default profile schema

## Source Data

Reference source tables using `{{ source('enterprise_db', 'TABLE_NAME') }}` syntax.

### ORDERS table (`ORDERS.ORDERS` via `{{ source('enterprise_db', 'ORDERS') }}`)
| Column | Type | Description |
|--------|------|-------------|
| order_id | VARCHAR | Unique order identifier |
| customer_id | VARCHAR | Customer identifier |
| ordered_at | TIMESTAMP | Order timestamp |
| grand_total | DECIMAL | Order total amount |
| status | VARCHAR | Order status (may contain leading/trailing whitespace) |

### ORDER_LINES table (`ORDER_LINES.ORDER_LINES` via `{{ source('enterprise_db', 'ORDER_LINES') }}`)
| Column | Type | Description |
|--------|------|-------------|
| ORDER_LINE_ID | VARCHAR | Unique line item identifier |
| ORDER_ID | VARCHAR | Reference to orders table |
| PRODUCT_ID | VARCHAR | Product identifier |
| PRODUCT_NAME | VARCHAR | Product name |
| QUANTITY_ORDERED | DECIMAL | Quantity ordered |
| UNIT_PRICE | DECIMAL | Price per unit |
| DISCOUNT_AMOUNT | DECIMAL | Discount applied to line (may be NULL) |
| LINE_TOTAL | DECIMAL | Total amount for line item |

## Required Models

### 1. Staging Model (`models/staging/stg_order_baskets.sql`)
Create order-level basket aggregations:

| Column | Type | Description |
|--------|------|-------------|
| order_id | VARCHAR | Order identifier |
| customer_id | VARCHAR | Customer identifier |
| order_date | DATE | Date of the order |
| order_month | INTEGER | Month number (1-12) extracted from order_date |
| order_half | VARCHAR | 'H1' for months 1-6, 'H2' for months 7-12 |
| order_quarter | VARCHAR | 'Q1' for months 1-3, 'Q2' for months 4-6, 'Q3' for months 7-9, 'Q4' for months 10-12 |
| distinct_items | INTEGER | Number of unique products in the basket |
| total_quantity | DECIMAL | Sum of all quantities ordered |
| basket_value | DECIMAL(12,2) | Sum of all line totals |
| total_discount | DECIMAL(12,2) | Sum of all discounts applied (treat NULL as 0) |
| avg_item_price | DECIMAL(10,2) | basket_value / distinct_items |
| max_line_value | DECIMAL(10,2) | Value of the most expensive line item |
| min_line_value | DECIMAL(10,2) | Value of the least expensive line item |
| price_range | DECIMAL(10,2) | Difference between max and min line value |

**Filtering rules**:
- Include only orders from 2024: `ordered_at >= '2024-01-01'` AND `ordered_at < '2025-01-01'`
- Exclude cancelled, returned, and failed orders: Apply `trim()` to the status column before filtering (e.g., `trim(status) NOT IN ('CANCELLED', 'RETURNED', 'FAILED')`)

### 2. Intermediate Model (`models/intermediate/int_customer_basket_patterns.sql`)
Analyze basket patterns at the customer level:

### 3. Intermediate Model (`models/intermediate/int_basket_transitions.sql`)
Track how customers transition between basket size categories over consecutive orders:

| Column | Type | Description |
|--------|------|-------------|
| from_category | VARCHAR | Starting basket size category |
| to_category | VARCHAR | Ending basket size category |
| transition_count | INTEGER | Number of times this transition occurred |
| transition_pct | DECIMAL(5,2) | Percentage of all transitions |
| avg_days_between | DECIMAL(8,2) | Average days between orders for this transition type |
| is_upgrade | BOOLEAN | TRUE if moving to a larger basket size category |
| is_downgrade | BOOLEAN | TRUE if moving to a smaller basket size category |

**Transition Logic**:
- For each customer, order their baskets chronologically by order_date (use order_id as tiebreaker for same-day orders)
- A transition occurs between consecutive orders: the previous order's category -> current order's category
- First orders have no "from" category (exclude them from transitions)
- Category size order for upgrade/downgrade: Single Item < Small Basket < Medium Basket < Large Basket

**Note**: Only include transitions where the customer has at least 2 orders (i.e., at least one transition exists).


| Column | Type | Description |
|--------|------|-------------|
| customer_id | VARCHAR | Customer identifier |
| total_orders | INTEGER | Total number of orders by this customer |
| avg_basket_size | DECIMAL(8,2) | Average distinct items per order |
| avg_basket_value | DECIMAL(10,2) | Average basket value per order |
| total_items_purchased | DECIMAL(10,2) | Sum of total_quantity across all orders |
| total_spent | DECIMAL(12,2) | Sum of basket_value across all orders |
| max_basket_size | INTEGER | Largest number of distinct items in any single order |
| max_basket_value | DECIMAL(10,2) | Highest basket value in any single order |
| single_item_orders | INTEGER | Number of orders with exactly 1 distinct item |
| multi_item_orders | INTEGER | Number of orders with more than 1 distinct item |
| multi_item_ratio | DECIMAL(5,2) | Percentage of orders that are multi-item: (multi_item_orders / total_orders) * 100 |
| avg_price_range | DECIMAL(10,2) | Average price range across all customer orders |
| h1_orders | INTEGER | Number of orders in H1 (months 1-6) |
| h2_orders | INTEGER | Number of orders in H2 (months 7-12) |
| h1_revenue | DECIMAL(12,2) | Total basket_value in H1 |
| h2_revenue | DECIMAL(12,2) | Total basket_value in H2 |

### 4. Mart Model (`models/marts/basket_size_analysis.sql`)
Create a **table** with one row per basket size category containing aggregate metrics, with these columns in exact order (42 columns total):

| # | Column | Type | Description |
|---|--------|------|-------------|
| 1 | basket_size_category | VARCHAR | Size category (see classification rules below) |
| 2 | order_count | INTEGER | Number of orders in this category |
| 3 | total_revenue | DECIMAL(12,2) | Sum of basket_value for all orders in category |
| 4 | avg_basket_value | DECIMAL(10,2) | Average basket value for orders in category |
| 5 | avg_quantity_per_order | DECIMAL(8,2) | Average total quantity per order in category |
| 6 | total_customers | INTEGER | Number of unique customers with orders in this category |
| 7 | avg_discount_per_order | DECIMAL(10,2) | Average discount amount per order |
| 8 | order_share_pct | DECIMAL(5,2) | Percentage of total orders: (category orders / total orders) * 100 |
| 9 | revenue_share_pct | DECIMAL(5,2) | Percentage of total revenue: (category revenue / total revenue) * 100 |
| 10 | customer_share_pct | DECIMAL(5,2) | Percentage of customers who have placed orders in this category |
| 11 | avg_item_price | DECIMAL(10,2) | Average price per item across orders in category |
| 12 | revenue_per_customer | DECIMAL(10,2) | total_revenue / total_customers |
| 13 | size_index | DECIMAL(5,2) | Ratio of revenue share to order share |
| 14 | value_tier | VARCHAR | Value tier based on avg_basket_value (see rules below) |
| 15 | popularity_rank | INTEGER | Rank by order_count (1 = most popular), use dense rank |
| 16 | discount_efficiency | DECIMAL(5,2) | Ratio: total_revenue / (total_discount + 1) |
| 17 | avg_price_range | DECIMAL(10,2) | Average price range across orders in category |
| 18 | h1_order_count | INTEGER | Number of orders in H1 (months 1-6) |
| 19 | h2_order_count | INTEGER | Number of orders in H2 (months 7-12) |
| 20 | h1_revenue | DECIMAL(12,2) | Total revenue in H1 |
| 21 | h2_revenue | DECIMAL(12,2) | Total revenue in H2 |
| 22 | order_growth_rate | DECIMAL(5,2) | Half-over-half order growth: ((h2 - h1) / h1) * 100, NULL if h1 = 0 |
| 23 | revenue_growth_rate | DECIMAL(5,2) | Half-over-half revenue growth: ((h2 - h1) / h1) * 100, NULL if h1 = 0 or NULL |
| 24 | growth_trend | VARCHAR | Trend classification based on order_growth_rate (see rules below) |
| 25 | basket_efficiency_score | INTEGER | Composite efficiency score 5-100 (see calculation below) |
| 26 | growth_potential_score | INTEGER | Composite growth potential score 5-100 (see calculation below) |
| 27 | efficiency_tier | VARCHAR | Efficiency tier based on basket_efficiency_score |
| 28 | growth_tier | VARCHAR | Growth tier based on growth_potential_score |
| 29 | strategic_classification | VARCHAR | Strategic classification combining multiple factors (see rules below) |
| 30 | investment_priority | VARCHAR | Investment priority combining efficiency and growth (see rules below) |
| 31 | quarter_order_volatility | DECIMAL(8,2) | Population standard deviation of order counts across Q1-Q4 |
| 32 | category_momentum | DECIMAL(5,2) | Weighted momentum: (order_growth_rate * 0.4) + (revenue_growth_rate * 0.6), NULL if either is NULL |
| 33 | efficiency_vs_avg | DECIMAL(5,2) | Difference between this category's basket_efficiency_score and the average score across all categories |
| 34 | rank_consistency | INTEGER | Absolute difference between popularity_rank and revenue_rank (where revenue_rank = dense_rank by total_revenue DESC) |
| 35 | avg_customer_orders | DECIMAL(6,2) | Average orders per customer in this category (order_count / total_customers) |
| 36 | relative_discount_rate | DECIMAL(5,2) | This category's avg_discount_per_order as percentage of overall average discount across all categories |
| 37 | composite_score | INTEGER | Combined score: (basket_efficiency_score + growth_potential_score) / 2, rounded to nearest integer |
| 38 | performance_quadrant | VARCHAR | Classification based on efficiency_vs_avg and growth_potential_score (see rules below) |
| 39 | first_order_pct | DECIMAL(5,2) | Percentage of orders in this category that are first-time orders for that customer |
| 40 | repeat_customer_pct | DECIMAL(5,2) | Percentage of customers in this category who have placed 2+ total orders (any category) |
| 41 | upgrade_rate | DECIMAL(5,2) | Percentage of transitions FROM this category that go to a larger category |
| 42 | category_velocity_score | INTEGER | Composite score (0-100) measuring category dynamism (see calculation below) |

### Basket Size Category Classification Rules
Based on distinct_items (number of unique products in the basket):
- 'Single Item' when distinct_items = 1
- 'Small Basket' when distinct_items = 2
- 'Medium Basket' when distinct_items is between 3 and 4 (inclusive)
- 'Large Basket' when distinct_items >= 5

### Value Tier Classification Rules
Based on avg_basket_value for the category:
- 'Premium' when avg_basket_value >= 500
- 'Standard' when avg_basket_value >= 200 and below 500
- 'Economy' when avg_basket_value < 200

### Growth Trend Classification Rules
Based on order_growth_rate (evaluate in order, first match wins):
- 'Accelerating' when order_growth_rate > 20
- 'Growing' when order_growth_rate > 0
- 'Stable' when order_growth_rate = 0
- 'Declining' when order_growth_rate >= -20
- 'Contracting' when order_growth_rate < -20
- NULL when order_growth_rate is NULL

### Size Index Calculation
Measures how much revenue each basket size category generates relative to its order volume:
- Calculate as: revenue_share_pct / order_share_pct
- Round to 2 decimal places

### Basket Efficiency Score Calculation (5-100)
A composite score combining four weighted components using a tiered point system.

**Component 1 - Revenue Contribution (max 30 points)**: Score based on revenue ranking. Rank categories by revenue_share_pct descending (dense_rank). Award 30 points to rank 1, subtract 10 for each subsequent rank (minimum 0).

**Component 2 - Size Index (max 25 points)**: Tiered scoring based on size_index thresholds:
- >= 2.0: 25 points
- >= 1.5: 20 points
- >= 1.2: 15 points
- >= 1.0: 10 points
- < 1.0: 5 points

**Component 3 - Customer Reach (max 25 points)**: Tiered scoring based on customer_share_pct thresholds:
- >= 60%: 25 points
- >= 40%: 20 points
- >= 25%: 15 points
- >= 10%: 10 points
- < 10%: 5 points

**Component 4 - Value Efficiency (max 20 points)**: Premium = 20, Standard = 12, Economy = 5.

**Final Score**: Sum all components, bounded between 5 and 100, as INTEGER.

### Growth Potential Score Calculation (5-100)
A composite score assessing future growth potential through four components.

**Component 1 - Order Growth (max 35 points)**: Tiered scoring based on order_growth_rate (evaluate in order, first match wins):
- `> 50%`: 35 points
- `> 20%` (and <= 50%): 28 points
- `> 0%` (and <= 20%): 20 points
- `= 0%` (exactly zero): 10 points
- `>= -20%` (and < 0%): 5 points
- `< -20%`: 0 points
- NULL: 15 points

**Component 2 - Revenue Growth (max 30 points)**: Same tier structure as order growth (evaluate in order, first match wins):
- `> 50%`: 30 points
- `> 20%` (and <= 50%): 24 points
- `> 0%` (and <= 20%): 18 points
- `= 0%` (exactly zero): 9 points
- `>= -20%` (and < 0%): 4 points
- `< -20%`: 0 points
- NULL: 12 points

**Component 3 - Market Penetration (max 20 points)**: INVERSE relationship - untapped markets score higher. Points: <10% -> 20, <25% -> 15, <40% -> 10, <60% -> 5, >=60% -> 2.

**Component 4 - Value Headroom (max 15 points)**: Economy = 15, Standard = 10, Premium = 3.

**Final Score**: Sum all components, bounded between 5 and 100, as INTEGER.

### Efficiency Tier Rules
Based on basket_efficiency_score:
- 'High Performance' when score >= 75
- 'Good Performance' when score >= 55
- 'Average Performance' when score >= 35
- 'Needs Improvement' when score < 35

### Growth Tier Rules
Based on growth_potential_score:
- 'High Potential' when score >= 70
- 'Moderate Potential' when score >= 50
- 'Low Potential' when score >= 30
- 'Saturated' when score < 30

### Strategic Classification Rules
Combine value_tier and customer_share_pct to determine strategic priority. **Evaluate conditions in the order shown below** (first match wins):
1. 'Core Revenue Driver' when value_tier = 'Premium' AND customer_share_pct >= 25
2. 'Growth Opportunity' when value_tier IN ('Premium', 'Standard') AND customer_share_pct < 25
3. 'Volume Leader' when customer_share_pct >= 50 AND value_tier != 'Premium'
4. 'Niche Segment' otherwise

### Investment Priority Rules
Combine efficiency_tier and growth_tier to determine where to invest. **Evaluate conditions in the order shown below** (first match wins):
1. 'Star' when efficiency_tier = 'High Performance' AND growth_tier IN ('High Potential', 'Moderate Potential')
2. 'Cash Cow' when efficiency_tier IN ('High Performance', 'Good Performance') AND growth_tier IN ('Low Potential', 'Saturated')
3. 'Question Mark' when efficiency_tier IN ('Average Performance', 'Needs Improvement') AND growth_tier IN ('High Potential', 'Moderate Potential')
4. 'Underperformer' when efficiency_tier = 'Needs Improvement' AND growth_tier IN ('Low Potential', 'Saturated')
5. 'Stable Performer' otherwise

### Quarter Order Volatility Calculation
Calculate the population standard deviation of order counts across the four quarters (Q1, Q2, Q3, Q4) for each basket size category. Round to 2 decimal places.

### Category Momentum Calculation
A weighted combination of growth rates:
- Formula: (order_growth_rate * 0.4) + (revenue_growth_rate * 0.6)
- Round to 2 decimal places
- Return NULL if either order_growth_rate or revenue_growth_rate is NULL

### Efficiency vs Average Calculation
Calculate how each category's efficiency score compares to the average:
- Compute the average basket_efficiency_score across all categories
- Subtract the average from each category's score
- Round to 2 decimal places
- Positive values indicate above-average efficiency

### Rank Consistency Calculation
Measures how consistently a category ranks by volume vs. revenue:
- Calculate revenue_rank using dense_rank ordered by total_revenue descending
- Compute absolute difference: |popularity_rank - revenue_rank|
- A value of 0 means the category ranks the same by orders and by revenue

### Average Customer Orders Calculation
Simple ratio of order_count to total_customers for each category. Round to 2 decimal places.

### Relative Discount Rate Calculation
Compare this category's discounting to the overall average:
- Calculate the average of avg_discount_per_order across all categories
- Divide this category's avg_discount_per_order by that overall average
- Multiply by 100 to express as percentage
- Round to 2 decimal places

### Composite Score Calculation
Simple average of the two main scores:
- Formula: (basket_efficiency_score + growth_potential_score) / 2
- Round to nearest integer

### Performance Quadrant Classification
Classify categories into quadrants based on efficiency relative to average AND growth potential:
- 'Rising Star' when efficiency_vs_avg > 0 AND growth_potential_score >= 60
- 'Established Leader' when efficiency_vs_avg > 0 AND growth_potential_score < 60
- 'High Potential' when efficiency_vs_avg <= 0 AND growth_potential_score >= 60
- 'Needs Attention' when efficiency_vs_avg <= 0 AND growth_potential_score < 60

### First Order Percentage Calculation
For each basket size category, calculate what percentage of orders are first-time orders:
- A first-time order is the earliest order (by order_date, then order_id) for each customer
- Formula: (count of first-time orders in category / total orders in category) * 100
- Round to 2 decimal places

### Repeat Customer Percentage Calculation
For each basket size category, calculate what percentage of customers are repeat customers:
- A repeat customer is one who has placed 2 or more total orders (across all categories)
- Count unique customers in this category who have 2+ total orders
- Formula: (repeat customers in category / total customers in category) * 100
- Round to 2 decimal places

### Upgrade Rate Calculation
Using data from `int_basket_transitions`, calculate the upgrade rate for each category:
- For each category, find all transitions where `from_category` equals this category
- Calculate: (upgrade transitions / total transitions from this category) * 100
- An upgrade is when `is_upgrade = TRUE`
- If a category has no outgoing transitions (e.g., Large Basket often has none), set to NULL
- Round to 2 decimal places

### Category Velocity Score Calculation (0-100)
A composite score measuring how dynamic/active a category is, combining:

**Component 1 - Transition Activity (max 40 points)**:
- Count total transitions involving this category (as from OR to)
- Above average: 40 points; at or below: 20 points

**Component 2 - First-Time Buyer Attraction (max 30 points)**:
- >= 40%: 30 points
- >= 25%: 20 points
- >= 10%: 10 points
- < 10%: 5 points

**Component 3 - Customer Retention (max 30 points)**:
- >= 70%: 30 points
- >= 50%: 22 points
- >= 30%: 15 points
- < 30%: 8 points

**Final Score**: Sum all components, cast as INTEGER. Score naturally bounded 0-100.

### 5. Intermediate Model (`models/intermediate/int_customer_cohorts.sql`)
Analyze customer behavior based on their FIRST basket size category (cohort). Each customer belongs to exactly one cohort based on their first order in 2024.

| Column | Type | Description |
|--------|------|-------------|
| cohort_category | VARCHAR | The basket size category of the customer's FIRST order |
| cohort_size | INTEGER | Number of customers whose first order was in this category |
| total_cohort_orders | INTEGER | Total orders placed by customers in this cohort (including first order) |
| total_cohort_revenue | DECIMAL(12,2) | Total revenue from customers in this cohort |
| avg_orders_per_customer | DECIMAL(6,2) | Average orders per customer in cohort |
| repeat_rate | DECIMAL(5,2) | Percentage of cohort customers who placed 2+ orders |
| upgrade_rate | DECIMAL(5,2) | Percentage of cohort's non-first orders that were in a LARGER category than their first |
| downgrade_rate | DECIMAL(5,2) | Percentage of cohort's non-first orders that were in a SMALLER category than their first |
| same_category_rate | DECIMAL(5,2) | Percentage of cohort's non-first orders that were in the SAME category as their first |
| cohort_share_pct | DECIMAL(5,2) | Percentage of total customers in this cohort |

**Calculation Notes**:
- A customer's cohort is determined by their FIRST order (earliest order_date, use order_id as tiebreaker)
- upgrade_rate + downgrade_rate + same_category_rate should equal 100% for each cohort (within rounding tolerance)
- For cohorts where all customers only have 1 order, upgrade_rate, downgrade_rate, and same_category_rate should all be NULL
- Category size order: Single Item (1) < Small Basket (2) < Medium Basket (3) < Large Basket (4)
- Order results by cohort_size descending

### 6. Mart Model (`models/marts/transition_summary.sql`)
Create a **table** summarizing basket size transitions with these columns in exact order (8 columns total):

| # | Column | Type | Description |
|---|--------|------|-------------|
| 1 | category | VARCHAR | Basket size category |
| 2 | total_incoming_transitions | INTEGER | Total transitions TO this category from other categories |
| 3 | total_outgoing_transitions | INTEGER | Total transitions FROM this category to other categories |
| 4 | net_transition_flow | INTEGER | incoming - outgoing (positive = net gain, negative = net loss) |
| 5 | retention_transitions | INTEGER | Transitions where from_category = to_category = this category |
| 6 | inflow_rate | DECIMAL(5,2) | Percentage of all transitions that flow INTO this category |
| 7 | outflow_rate | DECIMAL(5,2) | Percentage of all transitions that flow OUT OF this category |
| 8 | transition_balance | VARCHAR | 'Net Gainer' if net_transition_flow > 0, 'Net Loser' if < 0, 'Balanced' if = 0 |

**Calculation Notes**:
- incoming_transitions: Count of transitions where to_category = this category AND from_category != this category
- outgoing_transitions: Count of transitions where from_category = this category AND to_category != this category
- retention_transitions: Count where from_category = to_category = this category (same category repeat)
- inflow_rate and outflow_rate: Calculate as percentage of total transitions across all categories
- Order results by category alphabetically (A-Z)

## Output Requirements

1. **Model Names**: All six models must exist with exact names specified (1 staging, 3 intermediate, 2 marts)
2. **Materialization**: The mart model must be materialized as TABLE (not view)
3. **Column Order**: Columns must appear in the EXACT order specified (42 columns total)
4. **Data Types**:
   - Monetary values rounded to 2 decimal places
   - Percentages rounded to 2 decimal places
   - Ranks and scores must be INTEGER type
   - All category/tier/classification columns must use exact string values as specified
5. **NULL Handling**:
   - order_growth_rate is NULL when h1_order_count = 0
   - revenue_growth_rate is NULL when h1_revenue = 0 or NULL
   - growth_trend is NULL when order_growth_rate is NULL
6. **Ordering**: Results ordered by order_count descending (most popular categories first)
7. **Idempotency**: Multiple dbt runs must produce identical results

## Technical Notes
- Use SQL syntax compatible with the database backend (DuckDB or Snowflake)
- For customer_share_pct, calculate the percentage of total unique customers (across all orders) who have at least one order in each category
- The total unique customers is the count of distinct customers across all orders in 2024
- Ensure deterministic results across multiple runs

**Note**: If your models appear in a different schema than expected, re-check your work and review how dbt handles schema naming when a custom schema is specified.

## Guidelines

- Use Jinja conditionals (`{% if target.type == 'snowflake' %}`) for DuckDB-specific vs Snowflake-specific syntax
