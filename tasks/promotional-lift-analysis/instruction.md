# Promotional Lift Analysis

Create a dbt model to analyze marketing promotion effectiveness by comparing redemption-driven sales against historical product performance.

## Environment

- **Project location**: Create a new standalone dbt project at `/app/dbt_project`
- **Schema**: `promo_analytics`

(Hint: If your models appear in a different schema than expected, re-check your work and review how dbt handles schema naming when a custom schema is specified.)

## Database Backend
This task supports both DuckDB and Snowflake. **Run `echo $DB_TYPE` in a shell BEFORE you write any code or spawn any subagents — the live env determines which backend the verifier runs against.** Do NOT assume a default from this prose. Build the single standalone project at `/app/dbt_project` (see above) regardless of backend.

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

Explore the database to find tables containing:
- Promotion definitions (names, dates, discount details)
- Promotion-to-product/brand mappings
- Promotion redemption records
- Orders and order line items (with test/sample/internal order flags)
- Product catalog with brand information

Look in the `MARKETING`, `ORDERS`, and `PRODUCT` schemas.

## Requirements

Create a dbt model `promo_lift_analysis` that calculates promotional effectiveness metrics:

1. **Promotion Scope Identification**:
   - Promotions can target specific products OR entire brands
   - For brand-level targeting, expand to all products with that brand
   - Get all targeted products for each promotion

2. **Historical Baseline Calculation**:
   - For each promotion's targeted products, calculate the average daily revenue over the 365 days before the promotion start date
   - Use ALL order lines matching the targeted products (regardless of whether the order used the promotion)
   - Use LINE_TOTAL from order lines for revenue calculation
   - Exclude test, sample, and internal orders (look for flag columns in orders table)
   - baseline_daily_avg = total_revenue / 365
   - If no historical orders exist for a promotion's targeted products, use 0.00 for baseline_daily_avg

3. **Promotion Period Metrics**:
   - Count redemption records (each redemption record = one order that redeemed the promotion)
   - Sum total discount given from redemptions
   - Calculate promotion duration in days (end_date - start_date + 1)
   - Calculate average discount per redemption
   - Exclude test/sample/internal orders from redemption counts

4. **Lift Estimation**:
   - Expected revenue (without promotion) = baseline_daily_avg * promotion_duration_days
   - Discount investment = sum of discount amounts from redemptions
   - redeemed_order_revenue = sum of full order totals (GRAND_TOTAL) for orders that redeemed the promotion
   - Estimated lift = redeemed_order_revenue - expected_revenue
   - roi_pct = (estimated_lift - discount_investment) / discount_investment * 100

5. **Filtering**:
   - Only include promotions with at least 1 redemption
   - Only include promotions that have at least 1 targeted product defined (targeted_products_count > 0)
   - Exclude test/sample/internal orders from all calculations

## Output

After running `dbt run`, export the model results to `/app/promo_lift_results.csv` with columns:
- `promotion_id` - promotion identifier
- `promotion_name` - promotion name
- `promotion_duration_days` - days from start to end date inclusive
- `targeted_products_count` - number of distinct products targeted (must be > 0)
- `redemption_count` - number of redemption records
- `total_discount_given` - sum of discount amounts (rounded to 2 decimals)
- `avg_discount_per_order` - average discount per redemption (rounded to 2 decimals)
- `baseline_daily_avg` - historical daily revenue for targeted products (rounded to 2 decimals)
- `redeemed_order_revenue` - sum of GRAND_TOTAL from orders that redeemed the promotion (rounded to 2 decimals)
- `estimated_lift` - calculated lift (rounded to 2 decimals)
- `roi_pct` - ROI percentage (rounded to 2 decimals, NULL if discount is 0)

Sort by `redemption_count` descending, then by `promotion_name` ascending.

Install additional libraries as needed.

## Guidelines
- Do NOT modify upstream staging models
- Do NOT change model materialization
- The SQL syntax should work on both DuckDB and Snowflake (ANSI SQL compatible)
