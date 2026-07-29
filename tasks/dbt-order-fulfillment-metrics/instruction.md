# Order Fulfillment Metrics with Performance Analysis

Build a dbt project that analyzes order fulfillment performance, processing times, and assigns performance tiers by order type.

## Files

- DuckDB: `/app/dbt_project` (create project here)
- Snowflake: `/app/dbt_project` (create project here)
- Target schema: `fulfillment_analytics`
- Reference transforms: `/app/dbt_transforms` (read-only, for reference)

**Important: Schema naming override required.** For Snowflake, you must override the `generate_schema_name` macro so that dbt uses the custom schema name exactly as specified (e.g. `fulfillment_analytics`), rather than prepending the target schema (which would produce `main_fulfillment_analytics`). Create or overwrite `macros/utils/generate_schema_name.sql` with a macro that returns the custom schema when one is provided.

## Database Backend

This task supports both DuckDB and Snowflake. **Run `echo $DB_TYPE` in a shell BEFORE you write any code or spawn any subagents — the live env determines which backend the verifier runs against.** Do NOT assume a default from this prose. Reference dbt projects exist at `/app/dbt_models_duckdb/` and `/app/dbt_models_snowflake/` for inspection only. Write your dbt project at `/app/dbt_project` — outputs in the reference directories are not graded.

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

## Source Tables

Explore the database to discover order and fulfillment data. The main schema contains order records with fulfillment timestamps and order type classifications. Key source table:

- **`ORDERS.ORDERS`** - Order header information with status, type, and timestamp fields

## Requirements

Create a dbt project with staging, intermediate, and marts layers.

### Staging Models (models/staging/)

Create staging models that clean and standardize the source data. Trim string fields and normalize status/type values to uppercase.

### Intermediate Models (models/intermediate/)

1. **int_order_fulfillment.sql** - Calculate per-order fulfillment metrics:
   - Only include valid orders (COMPLETED, DELIVERED, SHIPPED status)
   - Calculate processing time: days between ordered_at and shipped_at
   - Calculate delivery time: days between ordered_at and delivered_at
   - Mark whether the order was shipped (has shipped_at)
   - Mark whether the order was delivered (has delivered_at)

2. **int_order_type_aggregates.sql** - Aggregate metrics by order_type:
   - Total orders, shipped count, delivered count
   - Total and average revenue
   - Average, minimum, and maximum processing days (for shipped orders)
   - Average, minimum, and maximum delivery days (for delivered orders)
   - Calculate fulfillment rate (shipped / total * 100)
   - Calculate delivery rate (delivered / total * 100)

3. **int_order_type_rankings.sql** - Calculate rankings using window functions:
   - Volume rank using RANK() ordered by total_orders DESC
   - Revenue rank using RANK() ordered by total_revenue DESC
   - Volume percentile using PERCENT_RANK() ordered by total_orders
   - Calculate order type revenue share of total revenue

### Final Model (models/marts/)

Create **fct_fulfillment_by_order_type.sql** that produces the final fulfillment analysis:

- Include all metrics from intermediate layers
- Calculate efficiency score: (fulfillment_rate/100 * 0.4) + (delivery_rate/100 * 0.4) + ((1 / (avg_processing_days + 1)) * 0.2)
- Assign performance tier based on volume percentile:
  - **High Performance**: percentile >= 0.66
  - **Medium Performance**: percentile >= 0.33
  - **Low Performance**: percentile < 0.33
- Assign fulfillment grade based on fulfillment_rate:
  - **Excellent**: rate >= 90
  - **Good**: rate >= 70
  - **Average**: rate >= 50
  - **Poor**: rate < 50
- Round monetary values to 2 decimal places
- Round rates, percentages, and scores to 4 decimal places
- Round time values to 2 decimal places
- Materialize as a table

### Required Output Columns

The final `fct_fulfillment_by_order_type` table must have:
- order_type
- total_orders
- orders_shipped
- orders_delivered
- fulfillment_rate
- delivery_rate
- avg_processing_days
- min_processing_days
- max_processing_days
- avg_delivery_days
- min_delivery_days
- max_delivery_days
- total_revenue
- avg_order_value
- volume_rank
- revenue_rank
- volume_percentile
- revenue_share_pct
- efficiency_score
- performance_tier
- fulfillment_grade

## Validation

- No NULL values allowed in any column
- Each order_type should appear exactly once
- Fulfillment and delivery rates should be between 0 and 100
- All time values must be non-negative
- Revenue share percentages should sum to approximately 100
- Performance tier must be one of: High Performance, Medium Performance, Low Performance
- Fulfillment grade must be one of: Excellent, Good, Average, Poor

## Guidelines

- The SQL syntax should work on both DuckDB and Snowflake (ANSI SQL compatible)
- Ensure idempotent execution (multiple runs produce same results)
- Use explicit type casts where needed
- Handle NULL values appropriately
- Use `DATEDIFF` for date difference calculations (works on both backends)
- Use `CAST(x AS DOUBLE)` for explicit type casting
