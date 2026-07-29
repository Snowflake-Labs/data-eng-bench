# Customer Acquisition Channel Performance

## Objective

Build a dbt model `rpt_customer_acquisition_channel_performance_fixed` that evaluates marketing channels by the quality and value of customers they acquire, using first-touch attribution.

## Database Backend

This task supports both **DuckDB** and **Snowflake** backends. The `DB_TYPE` environment variable determines which backend to use (`duckdb` or `snowflake`).

- **DuckDB mode**: The model materializes in the `analytics` schema (table: `analytics.rpt_customer_acquisition_channel_performance_fixed`)
- **Snowflake mode**: The model materializes in the `main` schema (table: `main.rpt_customer_acquisition_channel_performance_fixed`)

## Project Setup

### DuckDB Mode
Create the dbt model in the `/app/dbt_project` directory. The model file should be located at:

`/app/dbt_project/models/marts/marketing/rpt_customer_acquisition_channel_performance_fixed.sql`

You may need to create the directory structure if it doesn't exist:
- `/app/dbt_project/models/marts/marketing/`

The dbt project should be configured to use the `analytics` schema for materialized models.

Before building the mart model, you must first build the staging models in `/app/dbt_models_duckdb`:
```bash
cd /app/dbt_models_duckdb && dbt deps && dbt run --select int_sales__orders_enriched stg_orders__orders
```

### Snowflake Mode
Use the pre-existing dbt project at `/app/dbt_models_snowflake`. Create a symlink so the project is also available at `/app/dbt_project`:
```bash
ln -sfn /app/dbt_models_snowflake /app/dbt_project
```

The staging models (`int_sales__orders_enriched`, `stg_orders__orders`) are already pre-built in the Snowflake clone. You only need to write and run the mart model.

Write the model to: `/app/dbt_models_snowflake/models/marts/marketing/rpt_customer_acquisition_channel_performance_fixed.sql`

## dbt Profile Setup

### DuckDB
```yaml
dbt_project:
  target: dev
  outputs:
    dev:
      type: duckdb
      path: /app/database/retail.duckdb
      schema: analytics
```

### Snowflake
Generate a `profiles.yml` in the project directory using Snowflake environment variables (`SNOWFLAKE_ACCOUNT`, `SNOWFLAKE_USER`, `SNOWFLAKE_PASSWORD`, `SNOWFLAKE_DATABASE`, `SNOWFLAKE_WAREHOUSE`, `SNOWFLAKE_ROLE`). Use the `retail_dw_master` profile with `schema: main`.

## Output Schema

The model should produce a table with the following columns:

- `acquisition_channel` (VARCHAR) - The channel that acquired the customer (first-touch attribution)
- `customer_count` (INTEGER) - Number of unique customers acquired through this channel
- `total_orders` (INTEGER) - Total number of orders placed by customers from this channel
- `total_revenue` (DECIMAL) - Total revenue from all orders by customers from this channel
- `average_order_value` (DECIMAL) - Average order value (AOV) = total_revenue / total_orders
- `customer_lifetime_value` (DECIMAL) - Average CLTV = total_revenue / customer_count
- `average_orders_per_customer` (DECIMAL) - Average number of orders per customer = total_orders / customer_count
- `repeat_purchase_rate` (DECIMAL) - Percentage of customers who placed 2+ orders = (customers with 2+ orders / customer_count) * 100
- `channel_tier` (VARCHAR) - Classification: 'HIGH_VALUE' (CLTV > 500 AND repeat_rate > 30%), 'VOLUME' (customer_count > 100 AND CLTV > 200), 'LOW_QUALITY' (CLTV < 100 OR repeat_rate < 10%), 'STANDARD' (all others)

## Business Rules

1. **Data Source**: Use `main.int_sales__orders_enriched` joined with `main.stg_orders__orders` (via order_id) to get UTM/attribution data.

2. **First-Touch Attribution**: For each customer, identify their first order (earliest `ordered_at`). Use the `attribution_channel` from that first order. If `attribution_channel` is NULL, derive it from `utm_source` and `utm_medium`:
   - If `utm_source` = 'google' AND `utm_medium` = 'cpc' -> 'PAID_SEARCH'
   - If `utm_source` = 'google' AND `utm_medium` = 'organic' -> 'ORGANIC_SEARCH'
   - If `utm_source` = 'facebook' OR `utm_source` = 'instagram' -> 'SOCIAL_MEDIA'
   - If `utm_source` = 'email' OR `utm_medium` = 'email' -> 'EMAIL'
   - If `utm_source` = 'direct' OR (utm_source IS NULL AND utm_medium IS NULL) -> 'DIRECT'
   - Otherwise -> COALESCE(attribution_channel, 'OTHER')

3. **Customer Metrics**: For each channel, aggregate:
   - Count distinct customers (those whose first order was via this channel)
   - Count distinct order IDs (`COUNT(DISTINCT order_id)`) from those customers that exist in both `int_sales__orders_enriched` and `stg_orders__orders` (i.e., orders that are part of the INNER JOIN result, not just all orders from those customers in `int_sales__orders_enriched`)
   - Sum all revenue from those orders (matching the order count above)
   - Calculate repeat purchase rate: customers with 2+ distinct orders / total customers * 100

   **Important**: When counting orders and revenue for customers, only include orders that are present in both `main.int_sales__orders_enriched` AND `main.stg_orders__orders` (via the INNER JOIN on `order_id`). Do not count all orders from those customers in `int_sales__orders_enriched` if they don't have a matching record in `stg_orders__orders`.

4. **Filtering**:
   - Exclude cancelled orders (`status != 'CANCELLED'`)
   - Only include customers with at least one valid order

5. **Channel Tier Logic**:
   - HIGH_VALUE: CLTV > 500 AND repeat_purchase_rate > 30%
   - VOLUME: customer_count > 100 AND CLTV > 200
   - LOW_QUALITY: CLTV < 100 OR repeat_purchase_rate < 10%
   - STANDARD: All others

## Expected Output

- One row per acquisition channel
- All metrics should be non-negative
- `repeat_purchase_rate` should be between 0 and 100
- `average_order_value` should equal `total_revenue / total_orders` (within rounding)
- `customer_lifetime_value` should equal `total_revenue / customer_count` (within rounding)
- `average_orders_per_customer` should equal `total_orders / customer_count` (within rounding)

## Guidelines

- Handle NULLs appropriately (use COALESCE where needed)
- Round monetary values to 2 decimal places
- Round percentages to 2 decimal places
- The model should be materialized as a table
- Use `adapter.get_relation()` to reference source tables from the `main` schema
- All SQL should be ANSI-compatible (avoid DuckDB-specific or Snowflake-specific syntax)
- **Schema Configuration**:
  - For DuckDB: Ensure your model materializes in the `analytics` schema exactly (not `main_analytics` or `analytics_analytics` or similar). Review dbt's schema naming conventions if needed.
  - For Snowflake: The model should materialize in the `main` schema (the default schema for the Snowflake profile).
