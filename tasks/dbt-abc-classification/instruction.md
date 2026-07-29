# ABC Inventory Classification (Pareto Analysis)

Build an ABC inventory classification system that categorizes products based on their revenue contribution using the Pareto principle (80/20 rule). This includes calculating running totals, cumulative percentages, ABC classifications, and generating insights about inventory value concentration.

## Environment

- **Analysis date**: December 1, 2024
- **Analysis period**: January 1, 2023 through November 30, 2024

## Files

- DuckDB: `/app/dbt_models_duckdb/models/` (dbt project: `/app/dbt_models_duckdb`)
- Snowflake: `/app/dbt_models_snowflake/models/` (dbt project: `/app/dbt_models_snowflake`)

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

## Source Data

The staging layer provides:

- `stg_orders__orders`: order_id, customer_id, ordered_at, grand_total, status, test_order_flag
- `stg_orders__order_lines`: order_line_id, order_id, product_id, product_name, quantity_ordered, unit_price, line_total, status
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
- line_total > 0

### Models to Create

Create these dbt models:

1. **Intermediate models** in `models/intermediate/`:
   - `int_abc_product_revenue`: Aggregated revenue metrics per product including total_revenue, total_quantity_sold, order_count, and avg_unit_price.

2. **Mart models** in `models/marts/analytics/`:
   - `abc_classification`: Product-level ABC classification with cumulative metrics (table)
   - `abc_summary`: Summary statistics by ABC class (table)
   - `abc_category_breakdown`: ABC distribution within each product category (table)

### ABC Classification Logic

Products are classified into three categories based on cumulative revenue contribution:

| Class | Cumulative Revenue Threshold | Description |
|-------|------------------------------|-------------|
| A | 0% to 80% | High-value products (vital few) |
| B | 80% to 95% | Medium-value products |
| C | 95% to 100% | Low-value products (trivial many) |

**Classification Process:**
1. Calculate total revenue per product
2. Rank products by revenue (descending)
3. Calculate each product's percentage of total revenue
4. Calculate cumulative percentage (running sum)
5. Assign class based on where cumulative percentage crosses thresholds

**Important**: The ABC class is determined by the cumulative percentage **after** including the current product. A product whose cumulative percentage is exactly 80% should be class A.

### Revenue Metrics

For each product, calculate:

- **total_revenue**: Sum of line_total from all qualifying order lines
- **total_quantity_sold**: Sum of quantity_ordered
- **order_count**: Count of distinct orders containing this product
- **avg_unit_price**: Average unit_price across all order lines (weighted by quantity)
- **avg_order_value**: total_revenue / order_count
- **revenue_pct**: Product's revenue as percentage of grand total (2 decimal places)
- **cumulative_revenue**: Running sum of revenue (ordered by revenue DESC, product_id ASC)
- **cumulative_revenue_pct**: Cumulative revenue as percentage of grand total (2 decimal places)

### Ranking Metrics

- **revenue_rank**: Dense rank by total_revenue DESC (1 = highest revenue)
- **quantity_rank**: Dense rank by total_quantity_sold DESC
- **product_count_rank**: Position in the sorted product list (1, 2, 3, ...)

### Concentration Analysis

Calculate metrics to understand revenue concentration:

- **products_for_80_pct**: Count of products needed to reach 80% of revenue
- **products_for_95_pct**: Count of products needed to reach 95% of revenue
- **is_pareto_product**: True if this product is in the top 20% of products by count AND contributes to top 80% of revenue

### Velocity and Trend Metrics

- **avg_monthly_revenue**: total_revenue / number of months with sales
- **first_sale_month**: Month of first sale (YYYY-MM format)
- **last_sale_month**: Month of last sale (YYYY-MM format)
- **months_active**: Count of distinct months with sales
- **revenue_velocity**: Categorize based on avg_monthly_revenue relative to overall average:
  - 'High': > 1.5x average
  - 'Medium': 0.5x to 1.5x average
  - 'Low': < 0.5x average

### Rounding Rules

- Round monetary values to 2 decimal places
- Round percentages to 2 decimal places
- Round quantities to integers
- Round averages to 2 decimal places

## Output: abc_classification

| Column | Type | Description |
|--------|------|-------------|
| product_id | string | Product identifier |
| product_name | string | Product name |
| category_id | string | Primary category ID |
| total_revenue | decimal(2) | Sum of line_total |
| total_quantity_sold | integer | Sum of quantity_ordered |
| order_count | integer | Distinct orders containing product |
| avg_unit_price | decimal(2) | Weighted average unit price |
| avg_order_value | decimal(2) | Average revenue per order |
| revenue_pct | decimal(2) | Percentage of total revenue |
| cumulative_revenue | decimal(2) | Running sum of revenue |
| cumulative_revenue_pct | decimal(2) | Cumulative percentage |
| revenue_rank | integer | Rank by revenue (1 = highest) |
| quantity_rank | integer | Rank by quantity sold |
| abc_class | string | A, B, or C |
| is_pareto_product | boolean | True if top 20% products contributing to 80% revenue |
| avg_monthly_revenue | decimal(2) | Revenue divided by months active |
| first_sale_month | string | First month with sales (YYYY-MM) |
| last_sale_month | string | Last month with sales (YYYY-MM) |
| months_active | integer | Count of months with sales |
| revenue_velocity | string | High/Medium/Low based on avg monthly revenue |

No NULL values allowed. Order by revenue_rank ASC (highest revenue first).

## Output: abc_summary

Summary statistics aggregated by ABC class.

| Column | Type | Description |
|--------|------|-------------|
| abc_class | string | A, B, or C |
| product_count | integer | Number of products in class |
| product_pct | decimal(2) | Percentage of total products |
| total_revenue | decimal(2) | Sum of revenue in class |
| revenue_pct | decimal(2) | Percentage of total revenue |
| total_quantity | integer | Sum of quantity sold |
| quantity_pct | decimal(2) | Percentage of total quantity |
| avg_revenue_per_product | decimal(2) | Average revenue per product in class |
| avg_orders_per_product | decimal(2) | Average order count per product |
| min_revenue | decimal(2) | Minimum product revenue in class |
| max_revenue | decimal(2) | Maximum product revenue in class |
| median_revenue | decimal(2) | Median product revenue in class |
| high_velocity_count | integer | Products with revenue_velocity = 'High' |
| medium_velocity_count | integer | Products with revenue_velocity = 'Medium' |
| low_velocity_count | integer | Products with revenue_velocity = 'Low' |

Order by abc_class ASC (A, B, C).

## Output: abc_category_breakdown

ABC distribution within each product category.

| Column | Type | Description |
|--------|------|-------------|
| category_id | string | Category identifier |
| total_products | integer | Total products in category |
| total_revenue | decimal(2) | Total category revenue |
| a_class_count | integer | Products classified as A |
| b_class_count | integer | Products classified as B |
| c_class_count | integer | Products classified as C |
| a_class_pct | decimal(2) | Percentage of products in A |
| b_class_pct | decimal(2) | Percentage of products in B |
| c_class_pct | decimal(2) | Percentage of products in C |
| a_class_revenue | decimal(2) | Revenue from A class products |
| b_class_revenue | decimal(2) | Revenue from B class products |
| c_class_revenue | decimal(2) | Revenue from C class products |
| a_revenue_pct | decimal(2) | Percentage of revenue from A |
| b_revenue_pct | decimal(2) | Percentage of revenue from B |
| c_revenue_pct | decimal(2) | Percentage of revenue from C |
| category_concentration | string | 'A-Heavy', 'Balanced', or 'C-Heavy' based on distribution |

**category_concentration** classification:
- 'A-Heavy': a_revenue_pct >= 70%
- 'C-Heavy': c_revenue_pct >= 30%
- 'Balanced': otherwise

Order by total_revenue DESC.

## Materialization

- Intermediate models: views
- `abc_classification`: table
- `abc_summary`: table
- `abc_category_breakdown`: table

## Verification

```bash
# For DuckDB
cd /app/dbt_models_duckdb
dbt run --select +abc_classification +abc_summary +abc_category_breakdown

# For Snowflake
cd /app/dbt_models_snowflake
dbt run --select +abc_classification +abc_summary +abc_category_breakdown
```

## Guidelines

- The SQL syntax should work on both DuckDB and Snowflake (ANSI SQL compatible)
- Use TO_CHAR for date formatting (works on both) instead of strftime (DuckDB only)
