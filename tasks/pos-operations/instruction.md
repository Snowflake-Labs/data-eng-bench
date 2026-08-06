# Point of Sale Operations Dimensional Model

Build intermediate and mart models for POS operations analytics including order fulfillment analysis, payment method performance, product velocity metrics, return analysis, and order pattern detection.

## Your Task

Add dbt models to the existing project that create POS operations analytics dimensional models.

- DuckDB: `/app/dbt_models_duckdb/models/intermediate/pos/` and `/app/dbt_models_duckdb/models/marts/pos/`
- Snowflake: `/app/dbt_models_snowflake/models/intermediate/pos/` and `/app/dbt_models_snowflake/models/marts/pos/`

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

- Target schema: main

Note: If your models appear in a different schema than expected, re-check your work and review how dbt handles schema naming when a custom schema is specified.

## Source

Use existing staging models: stg_pos__* in models/staging/pos/

Note: Staging tables contain raw data with quality issues (formatting inconsistencies, invalid values, NULLs, potential duplicates). Use TRY_CAST for type conversions - it returns NULL for invalid values instead of erroring. Monetary values include $ signs and "USD" text that need to be stripped. Dates may be in MM/DD/YYYY format.

Note: When duplicates exist, filter to keep one row per primary key based on appropriate ordering criteria.

Note: All rate and percentage fields should be stored as decimal values (0.0 to 1.0 scale), not as percentages (0 to 100 scale). For example, a 25% return rate should be stored as 0.25, not 25.

Note: Total revenue in fct_order_daily_performance should match total revenue in fct_pos_orders within 1%.

## Required Models

### Intermediate Layer (models/intermediate/pos/)

#### int_pos__order_daily_summary
One row per (order_source, order_date) from stg_pos__transactions.

Columns: order_source, order_date (DATE from ordered_at), order_count, total_revenue (SUM of grand_total), total_items_sold (SUM of quantity_ordered from stg_pos__trans_lines), avg_order_value, avg_items_per_order

#### int_pos__order_timing
One row per ORDER_ID from stg_pos__transactions.

Columns: order_id, order_source, order_type, ordered_at, shipped_at, delivered_at, cancelled_at, order_to_ship_days (days between ordered_at and shipped_at), ship_to_delivery_days, total_fulfillment_days (days from ordered_at to delivered_at), is_cancelled (truthy if cancelled_at IS NOT NULL), is_delivered (truthy if delivered_at IS NOT NULL)

#### int_pos__payment_summary
One row per (order_source, payment_method) from stg_pos__transactions joined with stg_pos__tenders.

Columns: order_source, payment_method (from stg_pos__tenders), transaction_count (COUNT DISTINCT order_id), total_amount, avg_transaction_amount, payment_method_share (share of order_source's transaction count)

#### int_pos__product_velocity
One row per (variant_id, order_source) from stg_pos__trans_lines joined with stg_pos__transactions.

Columns: variant_id, order_source, units_sold, units_returned, total_revenue, order_count, avg_units_per_order, days_with_sales, velocity_score (units_sold / days_with_sales), return_rate (units_returned / units_sold)

#### int_pos__basket_metrics
One row per ORDER_ID from stg_pos__trans_lines.

Columns: order_id, basket_size (COUNT of line items), total_units, basket_value, avg_item_price, has_discount (truthy if any discount_amount > 0), total_discount, discount_rate (total_discount / (basket_value + total_discount), NULL if denominator is 0)

#### int_pos__order_status_summary
One row per (order_source, status, payment_status, fulfillment_status) from stg_pos__transactions.

Columns: order_source, status, payment_status, fulfillment_status, order_count, total_revenue, avg_order_value

#### int_pos__promotion_effectiveness
One row per promotion_id from stg_pos__promotions joined with order data.

To identify orders using promotions, join stg_pos__trans_lines to stg_pos__coupons (where discount_amount > 0 suggests coupon usage) and then to stg_pos__promotions.

Columns: promotion_id, promotion_code, promotion_name, promotion_type, discount_type, orders_with_promotion, total_discount_given, total_revenue (SUM of grand_total for promotion orders), avg_order_value, avg_discount_per_order

#### int_pos__return_summary
One row per (order_source, variant_id) from stg_pos__trans_lines where quantity_returned > 0.

Columns: order_source (from stg_pos__transactions), variant_id, return_count, total_units_returned, total_units_sold (for same product/source), return_rate, return_value (SUM of quantity_returned * unit_price)

### Marts Layer (models/marts/pos/)

#### dim_order_sources
One row per order_source from stg_pos__transactions. Exclude rows where order_source IS NULL.

Columns: order_source, order_count, total_revenue, first_order_date, last_order_date, is_active (truthy if last_order_date is within last 90 days from MAX ordered_at across all orders)

#### fct_pos_orders
One row per ORDER_ID from stg_pos__transactions.

Columns: order_id, order_number, customer_id, order_type, order_source, currency_code, subtotal, discount_total, shipping_total, tax_total, grand_total, status, payment_status, fulfillment_status, ordered_at, shipped_at, delivered_at, cancelled_at, order_to_ship_days, is_delivered, is_cancelled

#### fct_order_lines
One row per ORDER_LINE_ID from stg_pos__trans_lines.

Columns: order_line_id, order_id, line_number, variant_id, sku, product_name, quantity_ordered, quantity_shipped, quantity_returned, unit_price, discount_amount, tax_amount, line_total, status, has_return (truthy if quantity_returned > 0)

#### fct_order_daily_performance
One row per (order_source, order_date) from stg_pos__transactions.

Columns: order_source, order_date (DATE from ordered_at), order_count (default 0), total_revenue (default 0), total_items_sold (default 0), avg_order_value (NULL if no orders), avg_basket_size, cancelled_order_count (default 0), cancellation_rate (NULL if no orders), delivered_order_count (default 0), delivery_rate (NULL if no orders), avg_fulfillment_days (NULL if none delivered)

#### fct_payment_analysis
One row per (order_source, payment_method) from stg_pos__transactions joined with stg_pos__tenders.

Columns: order_source, payment_method, transaction_count (default 0), total_amount (default 0), avg_transaction_amount (NULL if no transactions), payment_method_share, successful_payment_count (status = 'COMPLETED' or 'APPROVED', default 0), success_rate (NULL if no payments)

#### fct_product_performance
One row per variant_id from stg_pos__trans_lines.

Columns: variant_id, sku, product_name, total_units_sold (default 0), total_units_returned (default 0), total_revenue (default 0), total_orders (default 0), avg_units_per_order (NULL if no orders), return_rate (NULL if no units sold), velocity_score (units_sold / days_with_sales, NULL if no days), velocity_category ('FAST' if velocity_score >= 5, 'MEDIUM' if >= 1 and < 5, 'SLOW' if < 1, NULL if no velocity_score)

#### fct_order_fulfillment
One row per ORDER_ID from stg_pos__transactions where status NOT IN ('CANCELLED', 'PENDING').

Columns: order_id, order_source, order_type, ordered_at, shipped_at, delivered_at, order_to_ship_days, ship_to_delivery_days, total_fulfillment_days, is_delivered, is_on_time (truthy if total_fulfillment_days <= 7, falsy if delivered but took longer, NULL if not delivered), fulfillment_tier ('EXCELLENT' if <= 3 days, 'GOOD' if <= 5, 'ACCEPTABLE' if <= 7, 'SLOW' if > 7, NULL if not delivered)

#### fct_return_analysis
One row per (order_source, variant_id) from stg_pos__trans_lines where quantity_returned > 0.

Columns: order_source, variant_id, product_name, return_count (default 0), total_units_returned (default 0), total_units_sold (default 0), return_rate (NULL if no units sold), return_value (default 0), return_risk_level ('CRITICAL' if return_rate >= 0.15, 'HIGH' if >= 0.10 and < 0.15, 'MEDIUM' if >= 0.05 and < 0.10, 'LOW' if < 0.05)

#### source_performance_scores
One row per order_source from stg_pos__transactions.

Columns: order_source, total_orders (default 0), total_revenue (default 0), avg_order_value (NULL if no orders), cancellation_rate (NULL if no orders), delivery_rate (NULL if no orders), performance_score (composite 0-100, see formula), performance_grade ('A' >= 90, 'B' >= 80, 'C' >= 70, 'D' >= 60, 'F' < 60), revenue_rank (1 = highest), order_rank (1 = highest)

Performance score formula:
- Revenue component (40 pts): Percentile rank of total_revenue * 40
- Order volume component (30 pts): Percentile rank of total_orders * 30
- Efficiency component (20 pts): Percentile rank of avg_order_value * 20
- Quality component (10 pts): delivery_rate * 10, capped at 10

Final score is sum of all components, rounded to 2 decimal places.

#### fct_promotion_performance
One row per promotion_id from stg_pos__promotions.

Columns: promotion_id, promotion_code, promotion_name, promotion_type, discount_type, orders_with_promotion (default 0), total_discount_given (default 0), total_revenue (default 0), avg_order_value (NULL if no orders), avg_discount_per_order (NULL if no orders), discount_to_revenue_ratio (total_discount_given / (total_revenue + total_discount_given), NULL if denominator is 0), promotion_effectiveness ('EXCELLENT' if orders >= 100 AND ratio < 0.15, 'GOOD' if orders >= 50 AND ratio < 0.25, 'FAIR' if orders >= 20, 'POOR' otherwise)

#### rpt_order_source_rankings
One row per order_source from stg_pos__transactions.

Columns: order_source, total_revenue (default 0), total_orders (default 0), avg_order_value (NULL if no orders), cancellation_rate (NULL if no orders), performance_score (from source_performance_scores), revenue_rank, order_rank, performance_rank, is_top_performer (truthy if performance_rank <= 3), is_underperformer (truthy if performance_rank is in bottom 25%)

#### bridge_order_product
One row per (order_id, variant_id) from stg_pos__trans_lines.

Columns: order_id, variant_id, units_ordered (default 0), units_returned (default 0), line_revenue (default 0), has_discount (truthy if discount_amount > 0), discount_amount (default 0)

#### fct_order_patterns
One row per ORDER_ID from stg_pos__transactions.

Columns: order_id, order_source, order_type, ordered_at, order_date (DATE from ordered_at), order_hour (EXTRACT hour), day_of_week (full day name in title case: 'Monday', 'Tuesday', etc.), is_weekend (truthy if Saturday or Sunday), basket_size, basket_value (grand_total), payment_method (from stg_pos__tenders, first payment method if multiple), is_high_value (truthy if basket_value exceeds the 75th percentile for this order_source), has_return (truthy if any line item has quantity_returned > 0)

## Guidelines

- Use Jinja conditionals (`{% if target.type == 'snowflake' %}`) where syntax diverges between backends
- Boolean columns should use integer representation (1/0) for cross-database compatibility
- Use DATEDIFF for date arithmetic, TRY_CAST for safe type conversions
- Always use `--select` with `dbt run` to specify which models to build
