# Product Affinity Analysis - Market Basket Optimization

## Context

You are working with a retail analytics database containing:
- 487 products across 30 categories
- 3,576 order lines across 2,037 orders

Your task is to build a complete product affinity and market basket analysis pipeline using dbt to help the merchandising team identify product bundles and cross-sell opportunities.

## Database Backend

This task supports both DuckDB and Snowflake. **Run `echo $DB_TYPE` in a shell BEFORE you write any code or spawn any subagents — the live env determines which backend the verifier runs against.** Do NOT assume a default from this prose. Both `/app/dbt_models_duckdb/` and `/app/dbt_models_snowflake/` exist on disk; the verifier only checks the project matching the live `$DB_TYPE`.

### DuckDB
- Set `DB_TYPE=duckdb`
- Database path: `$DUCKDB_PATH` (default: `/app/database/retail.duckdb`)
- dbt project: `/app/dbt_models_duckdb/`

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
- dbt project: `/app/dbt_models_snowflake/`

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

## Problem Statement

Build a product affinity analysis pipeline that:
1. Calculates product co-occurrence matrices from order data
2. Computes association rule metrics (support, confidence, lift, conviction)
3. Identifies high-affinity product pairs
4. Generates actionable product bundle recommendations

## Data Sources

Available tables in the database:
- `ORDERS.ORDER_LINES` - Individual line items in orders (3,576 records)
- `ORDERS.ORDERS` - Order header information (2,037 records)
- `PRODUCT.PRODUCTS` - Product catalog (487 products)
- `PRODUCT.PRODUCT_CATEGORIES` - Category definitions (30 categories)

**Data Quality Notes**:
- Some orders may have data quality issues that need handling
- Product categorization may require cleaning or interpretation
- Consider edge cases in your metric calculations (zero denominators, null values, single-product orders)
- Handle duplicate product entries within the same order appropriately

**Important data type note**:
- ID columns may be non-numeric in the source tables.
- Do not cast ID fields blindly; inspect the source schema and preserve compatible types.
- Tests accept VARCHAR/INTEGER/BIGINT for IDs, so use a type consistent with the source data.

## Required dbt Models

Create the following models in the dbt project directory:
- DuckDB: `/app/dbt_models_duckdb/models/`
- Snowflake: `/app/dbt_models_snowflake/models/`

### 1. `stg_basket__order_products.sql`
**Schema**: `staging`
**Purpose**: Stage order-product combinations for basket analysis

This model should denormalize the necessary order and product information needed for basket analysis. Include identifiers and descriptive attributes for both orders and products, ensuring you can track which products appear in which orders and their categorical groupings.

**Required columns**:
- `order_id` (VARCHAR)
- `product_id` (VARCHAR)
- `product_name` (VARCHAR)
- `category_id` (VARCHAR)
- `category_name` (VARCHAR)

### 2. `int_affinity__product_pairs.sql`
**Schema**: `intermediate`
**Purpose**: Generate all product pair combinations that appear together in orders

**Challenge**: Create a dataset of all unique, undirected product pairs that co-occur within the same order. Each pair should appear only once per order with `product_a_id < product_b_id` (avoid generating both (A,B) and (B,A) in this model). Include order context and relevant product/category information to support downstream analysis.

**Pair generation requirements**:
- Use distinct products per order (ignore duplicate product lines within the same order).
- Distinctness must be defined on product identity per order (not on descriptive fields that can vary).
- For each order with **N** distinct products, this model must contain exactly **N x (N - 1) / 2** rows (all unique pairs).

**Required columns**:
- `order_id` (VARCHAR)
- `product_a_id` (VARCHAR)
- `product_a_name` (VARCHAR)
- `product_b_id` (VARCHAR)
- `product_b_name` (VARCHAR)
- `category_a_id` (VARCHAR)
- `category_b_id` (VARCHAR)

### 3. `int_affinity__association_rules.sql`
**Schema**: `intermediate`
**Purpose**: Calculate association rule metrics for each product pair

This model should compute **directional** association rule metrics for each product pair. For every undirected pair (A,B) from `int_affinity__product_pairs`, this model must contain **two rows**: one for A->B and one for B->A. Include:
- Product pair identifiers and descriptive attributes for both products
- All four standard association rule metrics: **support**, **confidence**, **lift**, and **conviction**
- Supporting statistics that show how these metrics were calculated

**Required columns**:
- `product_a_id` (VARCHAR)
- `product_a_name` (VARCHAR)
- `product_b_id` (VARCHAR)
- `product_b_name` (VARCHAR)
- `support` (DOUBLE)
- `confidence` (DOUBLE)
- `lift` (DOUBLE)
- `conviction` (DOUBLE)
- `orders_with_both` (INTEGER)
- `orders_with_a` (INTEGER)
- `orders_with_b` (INTEGER)
- `total_orders` (INTEGER)

**Metric Requirements**:
Use the following formulas (directional A->B) based on **distinct orders**:
- **Support**: `orders_with_both / total_orders`
- **Confidence**: `orders_with_both / orders_with_a`
- **Lift**: `confidence / (orders_with_b / total_orders)`
- **Conviction**: `(1 - (orders_with_b / total_orders)) / NULLIF(1 - confidence, 0)`

All metrics must be mathematically correct and use consistent denominators. Handle divide-by-zero using `NULLIF` (or equivalent), and do not clamp values.

### 4. `fct_product_affinity_matrix.sql`
**Schema**: `marts`
**Purpose**: Final fact table with filtered high-affinity product pairs

This model should filter the **directional** association rules to identify high-quality product affinity relationships. Include:
- Product pair identifiers with descriptive names for both products
- Category information for both products (needed for filtering)
- All four association metrics (support, confidence, lift, conviction)
- Supporting count statistics

**Required columns**:
- `product_a_id` (VARCHAR)
- `product_a_name` (VARCHAR)
- `product_b_id` (VARCHAR)
- `product_b_name` (VARCHAR)
- `category_a_id` (VARCHAR)
- `category_b_id` (VARCHAR)
- `support` (DOUBLE)
- `confidence` (DOUBLE)
- `lift` (DOUBLE)
- `conviction` (DOUBLE)
- `orders_with_both` (INTEGER)

**Filtering Requirements**:
- Apply statistical thresholds to identify meaningful product relationships
- Filter out trivial associations (e.g., products that are too similar or naturally co-occur)
- Exclude patterns that don't represent intentional cross-category purchase behavior
- Balance between coverage and quality - aim for at least 100 high-lift pairs (lift > 1.5)

**Filtering thresholds**:
- You must define explicit thresholds for support, confidence, lift, and minimum co-occurrence.
- The filters must yield at least 100 directional pairs with lift > 1.5 while keeping all lift values > 1.0.

**Important**: Research standard market basket analysis filtering practices to determine appropriate thresholds for support, confidence, and lift that yield actionable insights.

### 5. `rpt_recommended_bundles.sql`
**Schema**: `marts`
**Purpose**: Top 50 product bundles for merchandising team

This final report should present the top 50 most promising product bundle opportunities for the merchandising team. Include:
- A ranking field showing priority order
- Product pair information (IDs and names for both products)
- Key metrics that justify the recommendation (focus on lift and confidence)
- Supporting evidence (transaction counts)

**Required columns**:
- `bundle_rank` (INTEGER) - Ranked by lift descending
- `product_a_id` (VARCHAR)
- `product_a_name` (VARCHAR)
- `product_b_id` (VARCHAR)
- `product_b_name` (VARCHAR)
- `lift` (DOUBLE)
- `confidence` (DOUBLE)
- `orders_with_both` (INTEGER)

Select the top 50 bundles **directly from `fct_product_affinity_matrix`** using this deterministic ordering:
1. `lift` DESC
2. `confidence` DESC
3. `orders_with_both` DESC
4. `product_a_id` ASC
5. `product_b_id` ASC

`bundle_rank` must be a dense 1..50 ranking derived from this ordering.

## Implementation Requirements

1. **Create all 5 models** in the appropriate schema folders:
   - Staging models: `models/staging/basket/`
   - Intermediate models: `models/intermediate/affinity/`
   - Mart models: `models/marts/merchandising/`

2. **Use dbt best practices**:
   - Use `{{ ref('model_name') }}` to reference upstream models
   - Add materialization configs (table or view)
   - Use CTEs for query organization
   - Use lowercase column names with explicit aliases: `SELECT ORDER_ID as order_id` (recommended for consistency)

3. **Schema targets**:
   - Your models must materialize into `main_staging`, `main_intermediate`, and `main_marts` schemas (as configured by dbt). Do not write into any other schema.

4. **Run the pipeline**:
    ```bash
    cd $DBT_PROJECT_DIR
    dbt deps
    dbt run --select stg_basket__order_products int_affinity__product_pairs int_affinity__association_rules fct_product_affinity_matrix rpt_recommended_bundles
    ```

## Expected Results

After running your models:
- `fct_product_affinity_matrix` should contain approximately 2,000+ high-affinity **directional** pairs
- All lift scores should be > 1.0 (indicating positive correlation)
- Support and confidence values between 0 and 1
- At least 100 directional pairs with lift > 1.5
- `rpt_recommended_bundles` should contain exactly 50 top bundles

## Validation Criteria

Your solution will be tested for:
1. All 5 required models exist and run successfully
2. Models contain appropriate columns with correct data types
3. Metric calculations are mathematically correct (support, confidence, lift, conviction)
4. Pair generation is correct (N x (N - 1) / 2 pairs per order, `product_a_id < product_b_id`)
5. Directional association rules exist for both A->B and B->A
6. Filtering rules are properly applied (category exclusion, quality thresholds)
7. At least 100 directional pairs with lift > 1.5
8. Top 50 bundles report contains exactly 50 rows and uses the required ordering
9. All lift values > 1.0 in final output

## Guidelines

- You must override `macros/utils/generate_schema_name.sql` to ensure custom schemas are used directly (not prefixed by dbt)
- Start with the staging model to understand the data structure
- Consider efficient approaches for generating product pair combinations
- Design your metric calculations to be reusable across models
- Test intermediate models before building final marts
- Use `dbt run --select model_name` to test individual models
- Research market basket analysis best practices if unfamiliar with the domain

## Tips

- Start with the staging model to understand the data structure
- Consider efficient approaches for generating product pair combinations
- Design your metric calculations to be reusable across models
- Test intermediate models before building final marts
- Use `dbt run --select model_name` to test individual models
- Research market basket analysis best practices if unfamiliar with the domain
