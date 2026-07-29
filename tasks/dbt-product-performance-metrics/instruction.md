# Product Performance Analytics

Build dbt models that analyze product-level sales performance, calculate return rates, classify products by revenue contribution using ABC analysis, assess product velocity, and compute a composite product health score.

## Data Environment
- **Analysis period**: Full year 2024 (January 1, 2024 to December 31, 2024)
- **Target schema**: `product_analytics` (will appear as `main_product_analytics` in database)

## Files
- DuckDB dbt project: `/app/dbt_models_duckdb/`
- Snowflake dbt project: `/app/dbt_models_snowflake/`

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

Reference source tables using `{{ source('enterprise_db', 'TABLE_NAME') }}` syntax.

### ORDERS table (`{{ source('enterprise_db', 'ORDERS') }}`)
| Column | Type | Description |
|--------|------|-------------|
| order_id | VARCHAR | Unique order identifier |
| customer_id | VARCHAR | Customer identifier |
| ordered_at | TIMESTAMP | Order timestamp |
| grand_total | DECIMAL | Order total amount |
| status | VARCHAR | Order status (may contain leading/trailing whitespace) |

### ORDER_LINES table (`{{ source('enterprise_db', 'ORDER_LINES') }}`)
| Column | Type | Description |
|--------|------|-------------|
| ORDER_LINE_ID | VARCHAR | Unique line item identifier |
| ORDER_ID | VARCHAR | Reference to orders table |
| PRODUCT_ID | VARCHAR | Product identifier |
| PRODUCT_NAME | VARCHAR | Product name |
| QUANTITY_ORDERED | DECIMAL | Quantity ordered |
| QUANTITY_RETURNED | DECIMAL | Quantity returned (0 if not returned) |
| UNIT_PRICE | DECIMAL | Price per unit |
| DISCOUNT_AMOUNT | DECIMAL | Discount applied to line |
| LINE_TOTAL | DECIMAL | Total amount for line item |
| STATUS | VARCHAR | Line item status |

### PRODUCTS table (`{{ source('enterprise_db', 'PRODUCTS') }}`)
| Column | Type | Description |
|--------|------|-------------|
| PRODUCT_ID | VARCHAR | Product identifier |
| PRODUCT_NAME | VARCHAR | Product name |
| PRODUCT_TYPE | VARCHAR | Type of product (PHYSICAL, DIGITAL) |
| PRIMARY_CATEGORY_ID | VARCHAR | Category reference |
| COST_PRICE | DECIMAL | Cost price (may be NULL) |

## Required Models

### 1. Staging Model (`models/staging/stg_order_lines__products.sql`)
Join order lines with their parent orders and filter to analysis period:

| Column | Type | Description |
|--------|------|-------------|
| order_line_id | VARCHAR | Line item identifier |
| order_id | VARCHAR | Order identifier |
| product_id | VARCHAR | Product identifier |
| product_name | VARCHAR | Product name (from ORDER_LINES) |
| order_date | DATE | Date of the order (from orders.ordered_at) |
| quantity_ordered | DECIMAL | Quantity ordered |
| quantity_returned | DECIMAL | Quantity returned |
| unit_price | DECIMAL | Unit price |
| discount_amount | DECIMAL | Discount amount |
| line_total | DECIMAL | Line total |

**Filtering rules**:
- Include only orders from 2024: `ordered_at >= '2024-01-01'` AND `ordered_at < '2025-01-01'`
- Exclude cancelled, returned, and failed orders: trim whitespace from order status before checking against 'CANCELLED', 'RETURNED', 'FAILED'
- Include all line item statuses (do not filter by ORDER_LINES.STATUS)

### 2. Intermediate Model (`models/intermediate/int_product_sales_summary.sql`)
Aggregate sales data at the product level:

| Column | Type | Description |
|--------|------|-------------|
| product_id | VARCHAR | Product identifier |
| product_name | VARCHAR | Product name (use most common name if multiple exist) |
| total_orders | INTEGER | Number of distinct orders containing this product |
| total_units_sold | DECIMAL | Sum of quantity_ordered |
| total_units_returned | DECIMAL | Sum of quantity_returned |
| gross_revenue | DECIMAL(12,2) | Sum of line_total before any adjustments |
| total_discounts | DECIMAL(12,2) | Sum of discount_amount |
| net_revenue | DECIMAL(12,2) | gross_revenue - total_discounts |
| avg_unit_price | DECIMAL(10,2) | Average unit price across all line items |
| avg_order_quantity | DECIMAL(8,2) | Average quantity per order (total_units_sold / total_orders) |

### 3. Mart Model (`models/marts/product_performance.sql`)
Create a **table** with one row per product containing performance metrics, with these columns in exact order:

| Column | Type | Description |
|--------|------|-------------|
| product_id | VARCHAR | Product identifier |
| product_name | VARCHAR | Product name |
| total_orders | INTEGER | Number of distinct orders containing this product |
| total_units_sold | DECIMAL(10,2) | Total units sold |
| total_units_returned | DECIMAL(10,2) | Total units returned |
| gross_revenue | DECIMAL(12,2) | Gross revenue |
| net_revenue | DECIMAL(12,2) | Net revenue after discounts |
| return_rate | DECIMAL(5,2) | Percentage of units returned (NULL if no units sold) |
| avg_revenue_per_order | DECIMAL(10,2) | net_revenue / total_orders |
| revenue_rank | INTEGER | Rank by net_revenue (1 = highest revenue) |
| revenue_contribution_pct | DECIMAL(5,2) | Percentage of total net revenue this product represents |
| cumulative_revenue_pct | DECIMAL(5,2) | Running cumulative percentage of revenue when ordered by net_revenue descending |
| abc_class | VARCHAR(1) | ABC classification based on cumulative revenue (see rules below) |
| order_frequency_rank | INTEGER | Rank by total_orders (1 = most orders) |
| velocity_class | VARCHAR | Product velocity classification (see rules below) |
| discount_intensity | DECIMAL(5,2) | Percentage of gross revenue given as discount |
| margin_indicator | VARCHAR | Margin indicator based on discount intensity (see rules below) |
| price_position | VARCHAR | How product's unit price compares to average (see rules below) |
| product_health_score | INTEGER | Composite score 0-100 combining multiple factors (see calculation below) |
| performance_tier | VARCHAR | Overall performance classification (see rules below) |

### ABC Classification Rules
Classify products based on their contribution to cumulative revenue (when products are ordered by net_revenue descending):
- 'A' for products that collectively contribute to the first 70% of total revenue
- 'B' for products that contribute to the next 20% of total revenue (70%-90% cumulative)
- 'C' for products that contribute to the remaining 10% of total revenue (above 90% cumulative)

### Velocity Class Rules
Divide all products into five equal-sized groups based on their order count (use NTILE(5) with deterministic ordering -- break ties by product_id ascending):
- 'Fast Mover' for products in the top 20% by order count
- 'Good Seller' for products in the 60th-80th percentile by order count
- 'Moderate' for products in the 40th-60th percentile by order count
- 'Slow Mover' for products in the 20th-40th percentile by order count
- 'Stagnant' for products in the bottom 20% by order count

### Margin Indicator Rules
Based on discount_intensity (percentage of gross revenue discounted):
- 'Healthy' when discount_intensity < 5
- 'Moderate' when discount_intensity >= 5 AND < 15
- 'Aggressive' when discount_intensity >= 15 AND < 25
- 'Deep Discount' when discount_intensity >= 25

### Price Position Rules
Compare each product's average unit price to the overall average unit price across all products:
- 'Premium' when the product's avg_unit_price is >= 1.5 times the overall average
- 'Above Average' when the product's avg_unit_price is >= 1.1 times but < 1.5 times the overall average
- 'Average' when the product's avg_unit_price is between 0.9 and 1.1 times the overall average
- 'Below Average' when the product's avg_unit_price is >= 0.5 times but < 0.9 times the overall average
- 'Budget' when the product's avg_unit_price is < 0.5 times the overall average

### Product Health Score Calculation (0-100)
A composite score combining four components:

1. **Revenue Component (0-35 points)**: Based on the product's position in the revenue distribution
   - Products at the top of revenue distribution receive 35 points
   - Products at the bottom receive 0 points
   - Scale linearly based on the product's percentile position in revenue

2. **Velocity Component (0-25 points)**: Based on velocity_class
   - 'Fast Mover' = 25 points
   - 'Good Seller' = 20 points
   - 'Moderate' = 15 points
   - 'Slow Mover' = 10 points
   - 'Stagnant' = 5 points

3. **Return Health Component (0-25 points)**: Based on return_rate (inverse relationship)
   - Return rate of 0% = 25 points
   - Return rate of 50% or higher = 0 points
   - Linear decay between these extremes
   - Products with NULL return_rate receive 25 points (no returns possible is healthy)

4. **Margin Component (0-15 points)**: Based on margin_indicator
   - 'Healthy' = 15 points
   - 'Moderate' = 10 points
   - 'Aggressive' = 5 points
   - 'Deep Discount' = 0 points

**Final Score**: Sum of all four components as an integer (minimum 5, maximum 100)

### Performance Tier Rules
Based on product_health_score:
- 'Star Performer' when score >= 80
- 'Strong Performer' when score >= 65 AND < 80
- 'Average Performer' when score >= 45 AND < 65
- 'Underperformer' when score >= 25 AND < 45
- 'At Risk' when score < 25

## Output Requirements

1. **Model Names**: All three models must exist with exact names specified
2. **Materialization**: The mart model must be materialized as TABLE (not view)
3. **Column Order**: Columns must appear in the exact order specified (20 columns total)
4. **Data Types**:
   - Monetary values rounded to 2 decimal places
   - Percentages rounded to 2 decimal places
   - Ranks must be INTEGER type
   - abc_class must be exactly 'A', 'B', or 'C'
   - velocity_class must be exactly 'Fast Mover', 'Good Seller', 'Moderate', 'Slow Mover', or 'Stagnant'
   - margin_indicator must be exactly 'Healthy', 'Moderate', 'Aggressive', or 'Deep Discount'
   - price_position must be exactly 'Premium', 'Above Average', 'Average', 'Below Average', or 'Budget'
   - product_health_score must be INTEGER between 0 and 100
   - performance_tier must be exactly 'Star Performer', 'Strong Performer', 'Average Performer', 'Underperformer', or 'At Risk'
5. **NULL Handling**:
   - return_rate should be NULL if total_units_sold is 0
6. **Ordering**: Results ordered by net_revenue descending (highest revenue products first)
7. **Idempotency**: Multiple dbt runs must produce identical results

## Guidelines
- For ABC classification, a product's class is determined by whether the cumulative percentage crosses the 70% or 90% threshold
- For ranking, products with the same value should receive the same rank
- Ensure deterministic results across multiple runs
- The overall average unit price for price_position should be calculated across all products (not weighted by quantity)
- The SQL syntax should work on both DuckDB and Snowflake (ANSI SQL compatible)
