# Multi-Currency LIFO Inventory Costing with Weighted Average Fallback

Build a dbt project that calculates Cost of Goods Sold (COGS) using LIFO (Last-In, First-Out) logic with multi-currency support, realized exchange rate tracking, and a weighted-average fallback costing layer.

## Files

- DuckDB: `/app/dbt_transforms` (create project here)
- Snowflake: `/app/dbt_transforms` (create project here)
- Target schema: `main`
- Reference transforms: `/app/dbt_models_duckdb` or `/app/dbt_models_snowflake` (read-only, for reference)

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

The database contains the following source tables. Explore them to understand available columns and data types.

1. **`FINANCE.CURRENCY_EXCHANGE_RATES`** - Daily exchange rates to USD
   - Key columns: `EFFECTIVE_DATE`, `FROM_CURRENCY`, `TO_CURRENCY`, `EXCHANGE_RATE`

2. **`PROCUREMENT.PURCHASE_ORDERS`** - Purchase order headers
   - Key columns: `PO_ID`, `CURRENCY_CODE`, `ORDERED_AT`

3. **`PROCUREMENT.PURCHASE_ORDER_LINES`** - Purchase order line items
   - Key columns: `PO_LINE_ID`, `PO_ID`, `SKU`, `QUANTITY_RECEIVED`, `UNIT_PRICE`

4. **`ORDERS.ORDERS`** - Sales order headers
   - Key columns: `ORDER_ID`, `ORDERED_AT`

5. **`ORDERS.ORDER_LINES`** - Sales order line items
   - Key columns: `ORDER_LINE_ID`, `ORDER_ID`, `SKU`, `QUANTITY_ORDERED`

## Project Setup

Create a dbt project at `/app/dbt_transforms`. The staging layer models are already available in the reference project. Use `dbt ls` or `dbt compile` commands to discover available staging models and their schemas.

## Guidelines

- The SQL syntax should work on both DuckDB and Snowflake (ANSI SQL compatible)
- Use `CAST(x AS DOUBLE)` instead of `::DOUBLE` for type casting
- Use `CAST(x AS INTEGER)` instead of `::INTEGER`
- Use `CAST(x AS DATE)` for date conversions
- Avoid DuckDB-specific or Snowflake-specific syntax

## Task Requirements

You need to build two new layers on top of the existing staging models:

**1. Intermediate Layer** (`models/intermediate/`):
Create intermediate models that transform staging data for downstream use. These should apply any necessary business transformations and prepare data for the marts layer. You must create the following intermediate models:
- `int_finance__exchange_rates_daily.sql` - processed exchange rates with proper date handling
- `int_procurement__purchases_enriched.sql` - purchases with header info joined
- `int_orders__sales_enriched.sql` - sales with header info joined

**2. Marts Layer** (`models/marts/`):
- `purchase_costs_usd.sql` - all purchases converted to USD
- `sale_cogs.sql` - COGS calculation for each sale using LIFO with weighted-average fallback costing for inventory shortfalls
- `inventory_turnover_metrics.sql` - SKU-level inventory analytics with turnover calculations

## Output Schema Requirements

Your final mart models must produce the following output schemas:

**purchase_costs_usd** must include these exact columns (case-sensitive, lowercase):
- `purchase_id` - unique identifier for each purchase line (from po_line_id)
- `sku` - product SKU
- `quantity` - quantity purchased (must be integer, use QUANTITY_RECEIVED)
- `original_currency` - currency code from purchase order
- `original_unit_cost` - unit cost in original currency (decimal with 4 precision)
- `purchase_date` - date of purchase (date type, not timestamp)
- `exchange_rate` - rate used to convert to USD (decimal with 6 precision)
- `unit_cost_usd` - unit cost after conversion to USD (decimal rounded to 4 places)
- `total_cost_usd` - total cost for this purchase line in USD (decimal rounded to 2 places)

**sale_cogs** must include these exact columns (case-sensitive, lowercase):
- `sale_id` - unique identifier for each sale (order_line_id, NOT order_id)
- `order_id` - the parent order identifier
- `sku` - product SKU
- `sale_date` - date of sale (date type, not timestamp)
- `quantity_sold` - quantity sold (must be integer)
- `cogs_usd` - total cost of goods sold in USD using LIFO (decimal rounded to 2 places)
- `avg_unit_cost` - average unit cost (decimal rounded to 4 places, 0.00 if quantity is 0)
- `batches_consumed` - number of distinct purchase batches used (integer)
- `inventory_shortfall` - quantity that could not be fulfilled from inventory (integer, 0 if fully fulfilled)
- `fallback_cost_usd` - weighted-average cost estimate for shortfall quantity (decimal rounded to 2 places, 0.00 if no shortfall)
- `total_estimated_cogs` - cogs_usd + fallback_cost_usd (decimal rounded to 2 places)
- `costing_method` - either 'LIFO_FULL', 'LIFO_PARTIAL', or 'LIFO_NONE' indicating how the sale was costed

**inventory_turnover_metrics** must include these exact columns (case-sensitive, lowercase):
- `sku` - product SKU
- `total_purchased_qty` - total quantity purchased across all batches (integer)
- `total_purchased_cost_usd` - total purchase cost in USD (decimal rounded to 2 places)
- `total_sold_qty` - total quantity sold (integer)
- `total_cogs_usd` - total COGS in USD (decimal rounded to 2 places)
- `remaining_inventory_qty` - ending inventory quantity (integer, can be negative if shortfall)
- `remaining_inventory_cost_usd` - estimated value of remaining inventory using LIFO layers (decimal rounded to 2 places)
- `weighted_avg_purchase_cost` - weighted average cost per unit across all purchases (decimal rounded to 4 places)
- `weighted_avg_sale_cost` - weighted average COGS per unit sold (decimal rounded to 4 places)
- `inventory_turnover_ratio` - total_cogs_usd / average_inventory_cost, using (starting + ending) / 2 (decimal rounded to 4 places, NULL if cannot calculate)
- `gross_margin_pct` - this field is only for SKUs where a standard sale price exists; leave NULL otherwise

## Business Rules

1. **Currency Conversion**: Convert all purchase costs to USD using the exchange rate on the purchase date. If no exchange rate exists for the exact purchase date, use the most recent available rate prior to that date. For purchases already in USD, the exchange rate should be 1.0. If no rate is available for a non-USD currency, the purchase should be excluded from the output.

2. **LIFO Logic**: Implement Periodic Last-In-First-Out (LIFO) inventory costing. In periodic LIFO, all purchases for the entire period are considered as one pool of inventory. When calculating COGS for sales, the most recently purchased inventory (latest purchase date) should be matched first. Multiple sales can be fulfilled from the same purchase batch. If multiple purchases occur on the same date, treat the purchase with the higher purchase_id as the more recent one (break ties by purchase_id DESC). Sales should be processed in chronological order (by sale_date, then by sale_id for same-date sales).

3. **Batch Consumption**: Track how many distinct purchase batches are consumed to fulfill each sale. A batch is only counted if it contributes at least some quantity to the sale.

4. **Weighted Average Fallback Costing**: When a sale cannot be fully fulfilled from inventory (shortfall > 0), calculate a fallback cost using the weighted average unit cost of all purchases for that SKU. The fallback_cost_usd equals shortfall quantity multiplied by the weighted average cost per unit. This provides a reasonable cost estimate for inventory that was expected but not available.

5. **Costing Method Classification**:
   - `LIFO_FULL`: All units were fulfilled from inventory (inventory_shortfall = 0)
   - `LIFO_PARTIAL`: Some units were fulfilled from inventory but there was a shortfall (inventory_shortfall > 0 AND batches_consumed > 0)
   - `LIFO_NONE`: No inventory was available (inventory_shortfall = quantity_sold AND batches_consumed = 0)

6. **Cost Precision**:
   - unit_cost_usd: rounded to 4 decimal places
   - total_cost_usd: rounded to 2 decimal places
   - cogs_usd: rounded to 2 decimal places
   - avg_unit_cost: rounded to 4 decimal places
   - batches_consumed and inventory_shortfall: must be integers

7. **Edge Cases**:
   - If available inventory is insufficient to fulfill a sale, calculate COGS based on available inventory only and record the shortfall in inventory_shortfall.
   - All sales must be included in the output even if there is zero inventory available (cogs_usd=0, batches_consumed=0, inventory_shortfall=quantity_sold).
   - Handle NULL values in source data gracefully - exclude records with NULL SKU, NULL quantity, or NULL unit_price.
   - Quantities must be positive integers (exclude zero or negative quantities).
   - When a single purchase batch is partially consumed across multiple sales, correctly track the remaining quantity for subsequent sales.

8. **Same-Day Purchase-Sale Handling**: When a purchase and sale occur on the same date, that purchase IS available for that sale (purchases are considered received at start of day). The LIFO ordering still applies - newer purchases consumed first.

9. **Duplicate SKU Handling**: If the same SKU appears in multiple currencies or from multiple suppliers, treat them as separate inventory batches. LIFO order is determined by purchase_date and purchase_id, regardless of currency.

10. **Partial Batch Tracking**: When a purchase batch is partially consumed by one sale, the remaining quantity must be correctly tracked and available for subsequent sales in LIFO order.

11. **Inventory Turnover Calculation**: For the turnover ratio, use the formula: Total COGS / Average Inventory Value. Average inventory value is calculated as (Beginning Inventory Value + Ending Inventory Value) / 2. For this task, assume beginning inventory is zero. Ending inventory value is calculated using LIFO layers (oldest costs remain).

12. **Remaining Inventory Valuation**: When calculating remaining_inventory_cost_usd, use the oldest purchase batches first (FIFO order for remaining inventory since LIFO consumption means oldest batches remain). If remaining_inventory_qty is negative (shortfall situation), set remaining_inventory_cost_usd to 0.

13. **Idempotency**: The solution must produce identical results when dbt run is executed multiple times without clearing state.

## Data Source

This task uses synthetic data generated for testing multi-currency LIFO inventory costing scenarios.
