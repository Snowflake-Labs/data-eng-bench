### Task: Advanced Customer Cross-Sell Insights -- Expert Mode

Build a comprehensive **cross-sell insights** analytics mart in a dbt project at `/app/dbt_project`. The project should implement association rule mining metrics, temporal decay, category hierarchies, and multi-dimensional analysis.

Implement **four models**:

1. `models/marts/products/rpt_cross_sell_insights.sql` -- Base cross-sell metrics with advanced association rules
2. `models/marts/products/rpt_cross_sell_trends.sql` -- Time-based cross-sell trends with exponential decay
3. `models/marts/customer/rpt_cross_sell_by_segment.sql` -- Cross-sell insights by customer segment with category analysis
4. `models/marts/products/rpt_cross_sell_category_hierarchy.sql` -- Cross-sell patterns across product category hierarchies

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
Configure with `type: duckdb` and the database path from `$DUCKDB_PATH`. Set schema to `analytics`.

### Snowflake Profile
Configure with `type: snowflake` using password authentication:
- Use the environment variables for account, user, database, schema, warehouse, and role
- Set schema to `analytics`

## Source Data

The database contains the following key source tables. Explore them to understand available columns.

- **`main.int_sales__order_lines`** -- Order line items with SKU, order_id, quantity_ordered
- **`main.int_sales__orders_enriched`** -- Order header with order_id, customer_id, grand_total, ordered_at, is_cancelled
- **`main.int_customers__unified`** -- Customer dimension with customer_id
- **`main.dim_product_variants`** -- Product variant dimension with sku, product_id
- **`main.stg_product__product_category_mapping`** -- Maps products to categories (product_id, category_id, is_primary, sort_order)
- **`main.stg_product__product_categories`** -- Category names (category_id, category_name)

For DuckDB, reference these via `main.<table_name>`. For Snowflake, these models are pre-built in the `main` schema of the clone database. Build dependent models via `/app/dbt_transforms` if needed (`dbt run --select int_sales__order_lines int_sales__orders_enriched`).

## Project Setup

1. Create a dbt project at `/app/dbt_project`
2. Configure `profiles.yml` with profile name `retail_dw_master` and schema `analytics`
3. Set `DBT_PROFILES_DIR` to the project directory

#### Model 1: Base Cross-Sell Insights (`analytics.rpt_cross_sell_insights`)

**Output columns:**
- `sku_a` (VARCHAR) -- canonical ordering: `sku_a < sku_b` lexicographically
- `sku_b` (VARCHAR)
- `orders_with_a` (INTEGER) -- distinct orders containing SKU A
- `orders_with_b` (INTEGER) -- distinct orders containing SKU B
- `orders_with_both` (INTEGER) -- distinct orders containing both SKUs
- `support` (DECIMAL(18,6)) -- `orders_with_both / total_eligible_orders`
- `confidence_a_to_b` (DECIMAL(18,6)) -- `orders_with_both / orders_with_a`
- `confidence_b_to_a` (DECIMAL(18,6)) -- `orders_with_both / orders_with_b`
- `lift_a_to_b` (DECIMAL(18,6)) -- `confidence_a_to_b / (orders_with_b / total_eligible_orders)`
- `lift_b_to_a` (DECIMAL(18,6)) -- `confidence_b_to_a / (orders_with_a / total_eligible_orders)`
- `conviction_a_to_b` (DECIMAL(18,6)) -- `(1 - orders_with_b / total_eligible_orders) / (1 - confidence_a_to_b)` when denominator > 0, else NULL
- `leverage_a_to_b` (DECIMAL(18,6)) -- `support - (orders_with_a / total_eligible_orders) * (orders_with_b / total_eligible_orders)`
- `kulczynski_measure` (DECIMAL(18,6)) -- `0.5 * (confidence_a_to_b + confidence_b_to_a)`
- `jaccard_coefficient` (DECIMAL(18,6)) -- `orders_with_both / (orders_with_a + orders_with_b - orders_with_both)`
- `cosine_similarity` (DECIMAL(18,6)) -- `orders_with_both / SQRT(orders_with_a * orders_with_b)`
- `avg_revenue_per_order_with_both` (DECIMAL(18,2)) -- average order revenue for orders containing both SKUs
- `total_revenue_with_both` (DECIMAL(18,2)) -- sum of order revenue for orders containing both SKUs
- `revenue_weighted_support` (DECIMAL(18,6)) -- `total_revenue_with_both / total_revenue_all_eligible_orders`
- `avg_quantity_per_order_with_both` (DECIMAL(18,2)) -- average total quantity (sum of quantity_ordered) for orders containing both SKUs
- `max_orders_in_single_day` (INTEGER) -- maximum number of orders containing both SKUs on any single day

**Business rules:**
- Source: `main.int_sales__order_lines` for SKU pairs.
- Source for revenue: `main.int_sales__orders_enriched`, join on `order_id` to get `grand_total` per order.
- Source for dates: `main.int_sales__orders_enriched`, extract `ordered_at` date (DATE, not timestamp).
- Eligible order universe: orders with at least two distinct non-NULL SKUs AND `is_cancelled = false` (or NULL).
- Within each order, treat SKU presence as binary (deduplicate SKUs per order before pairing).
- Pair generation: for every eligible order, emit all unordered pairs with `sku_a < sku_b`.
- Aggregations:
  - `total_eligible_orders` = count of distinct eligible orders.
  - `total_revenue_all_eligible_orders` = sum of `grand_total` from `int_sales__orders_enriched` for eligible orders.
  - `orders_with_a`, `orders_with_b` = eligible orders containing SKU A/B.
  - `orders_with_both` = eligible orders containing both SKUs.
  - Revenue metrics computed only for orders containing both SKUs.
  - `avg_quantity_per_order_with_both` = average of SUM(quantity_ordered) per order for orders containing both SKUs.
  - `max_orders_in_single_day` = maximum count of distinct orders containing both SKUs grouped by DATE(ordered_at).
- Filtering: exclude pairs where `support < 0.005` OR `orders_with_both < 3` OR `jaccard_coefficient < 0.001`.
- Guardrails:
  - Exclude NULL SKUs entirely.
  - `orders_with_both <= orders_with_a` and `<= orders_with_b`.
  - Metrics non-negative where applicable; denominators must not divide by zero (use NULLIF).
  - Round rate metrics to 6 decimal places, revenue to 2 decimal places.
  - All similarity metrics (jaccard, cosine, kulczynski) must be between 0 and 1 (inclusive).

#### Model 2: Cross-Sell Trends with Temporal Decay (`analytics.rpt_cross_sell_trends`)

**Output columns:**
- `sku_a` (VARCHAR)
- `sku_b` (VARCHAR)
- `year` (INTEGER)
- `quarter` (INTEGER) -- 1, 2, 3, or 4
- `month` (INTEGER) -- 1-12
- `orders_with_both` (INTEGER) -- distinct orders containing both SKUs in this period
- `support` (DECIMAL(18,6)) -- `orders_with_both / total_eligible_orders_in_period`
- `confidence_a_to_b` (DECIMAL(18,6))
- `lift_a_to_b` (DECIMAL(18,6))
- `quarter_over_quarter_change` (DECIMAL(18,6)) -- `(support - prev_quarter_support) / NULLIF(prev_quarter_support, 0)` where prev_quarter_support is from the previous quarter (NULL for Q1)
- `month_over_month_change` (DECIMAL(18,6)) -- `(support - prev_month_support) / NULLIF(prev_month_support, 0)` where prev_month_support is from the previous month (NULL for first month of data)
- `exponential_decay_weight` (DECIMAL(18,6)) -- `EXP(-0.1 * days_since_most_recent_order)` normalized to [0,1]
- `decay_weighted_support` (DECIMAL(18,6)) -- `support * exponential_decay_weight`

**Business rules:**
- Source: same as Model 1, filter orders by `ordered_at` date from `int_sales__orders_enriched`.
- Extract `year`, `quarter` (1-4), and `month` (1-12) from `ordered_at`.
- Only include pairs that exist in Model 1 (same filtering thresholds).
- For each period (year-quarter-month), compute metrics against eligible orders in that period only.
- `quarter_over_quarter_change` compares current quarter support to previous quarter support for the same pair (NULL for Q1 of each year or if previous quarter has no data).
- `month_over_month_change` compares current month support to previous month support (NULL for first month of data or if previous month has no data).
- `exponential_decay_weight`: compute `MAX(ordered_at)` per period, then `EXP(-0.1 * DATEDIFF('day', MAX(ordered_at), <reference_date>))` where `<reference_date>` is the most recent order date across all eligible (non-cancelled) orders. Do NOT use CURRENT_DATE. Normalize by dividing by the maximum decay weight across all periods for that pair.

#### Model 3: Cross-Sell by Customer Segment with Category Analysis (`analytics.rpt_cross_sell_by_segment`)

**Output columns:**
- `customer_segment` (VARCHAR) -- derived from customer data
- `sku_a` (VARCHAR)
- `sku_b` (VARCHAR)
- `orders_with_both` (INTEGER)
- `support` (DECIMAL(18,6)) -- `orders_with_both / total_eligible_orders_in_segment`
- `confidence_a_to_b` (DECIMAL(18,6))
- `lift_a_to_b` (DECIMAL(18,6))
- `avg_order_value_with_both` (DECIMAL(18,2))
- `category_a` (VARCHAR) -- product category for SKU A (NULL if not found)
- `category_b` (VARCHAR) -- product category for SKU B
- `same_category_flag` (BOOLEAN) -- TRUE if category_a = category_b (both non-NULL), else FALSE
- `cross_category_lift` (DECIMAL(18,6)) -- `lift_a_to_b` when `same_category_flag = FALSE`, else NULL

**Business rules:**
- Customer segment logic:
  - Compute `customer_lifetime_value` = SUM(`grand_total`) from `int_sales__orders_enriched` per customer (all time, excluding cancelled orders).
  - If `customer_lifetime_value` >= 10000: `'high_value'`
  - Else if >= 5000: `'medium_value'`
  - Else if >= 1000: `'low_value'`
  - Else: `'new'`
  - If `customer_lifetime_value` IS NULL or customer has no orders: `'unknown'`
- Product category: join to `main.dim_product_variants` on `sku`, then to product category mapping to get `category_name`. If SKU not found, set category to NULL.
- Only include pairs that exist in Model 1.
- Compute metrics per segment.
- `cross_category_lift` is only computed for pairs where categories differ.

#### Model 4: Cross-Sell Category Hierarchy (`analytics.rpt_cross_sell_category_hierarchy`)

**Output columns:**
- `category_a` (VARCHAR)
- `category_b` (VARCHAR)
- `orders_with_category_a` (INTEGER)
- `orders_with_category_b` (INTEGER)
- `orders_with_both_categories` (INTEGER)
- `category_support` (DECIMAL(18,6)) -- `orders_with_both_categories / total_eligible_orders`
- `category_confidence_a_to_b` (DECIMAL(18,6)) -- `orders_with_both_categories / orders_with_category_a`
- `category_lift_a_to_b` (DECIMAL(18,6))
- `avg_skus_per_order_with_both` (DECIMAL(18,2))
- `total_revenue_with_both_categories` (DECIMAL(18,2))

**Business rules:**
- Product category: join to `main.dim_product_variants` on `sku` to get `category` field.
- Eligible order universe: same as Model 1.
- For each order, collect all distinct categories from SKUs.
- Pair generation: all unordered category pairs with `category_a < category_b`.
- Filtering: exclude pairs where `category_support < 0.01` OR `orders_with_both_categories < 5` OR either category is NULL.
- Canonical ordering: `category_a < category_b`.

#### Quality + consistency requirements

**All models:**
- Canonical pairs only (`sku_a < sku_b` or `category_a < category_b`), no duplicates.
- Support/confidence/lift computed against the same eligible order universe within each model/segment/period.
- Metrics must be NULL only when denominators are zero.
- Idempotent: rerunning dbt should leave counts and sums unchanged.

**Model 1 specific:**
- All pairs must satisfy `support >= 0.005` AND `orders_with_both >= 3` AND `jaccard_coefficient >= 0.001`.
- `conviction_a_to_b` is NULL when `confidence_a_to_b = 1`.
- Similarity metrics (jaccard, cosine, kulczynski) must be in [0, 1].

**Model 2 specific:**
- Quarter values must be valid (1-4), month (1-12).
- `exponential_decay_weight` must be in (0, 1].

**Model 3 specific:**
- Customer segment must be one of: `'high_value'`, `'medium_value'`, `'low_value'`, `'new'`, `'unknown'`.
- `cross_category_lift` is NULL when `same_category_flag = TRUE`.

**Model 4 specific:**
- All pairs must satisfy `category_support >= 0.01` AND `orders_with_both_categories >= 5`.
- Categories must be non-NULL.

## Guidelines

- The SQL syntax should work on both DuckDB and Snowflake (ANSI SQL compatible).
- Use explicit type casts where needed. Use `CAST(x AS DOUBLE)` for division precision.
- Handle NULL values appropriately with NULLIF and COALESCE.
- Keep joins and aggregates deterministic; avoid fanout by deduplicating SKUs per order before pairing.
- Models should be materialized as `table` type.
- Build order: Model 1 first, then Models 2, 3, and 4 can depend on Model 1's filtering logic.
- If `dim_product_variants` or equivalent product dimension table does not exist, Models 3 and 4 should handle NULL categories gracefully.
- Ensure idempotent execution (multiple runs produce same results).
