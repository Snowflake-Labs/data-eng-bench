You are building a data reconciliation layer for order financial totals using dbt.

============================================================
DATABASE BACKEND
============================================================
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

============================================================
dbt Profile Setup
============================================================
You must configure dbt to connect to the database:
- Create a `profiles.yml` in the dbt project directory with profile name matching your `dbt_project.yml`
- Set `DBT_PROFILES_DIR` environment variable to the directory containing `profiles.yml`

### DuckDB Profile
Configure with `type: duckdb` and the database path from `$DUCKDB_PATH`.

### Snowflake Profile
Configure with `type: snowflake` using password authentication:
- Use the environment variables for account, user, password, database, schema, warehouse, and role

============================================================
SOURCE TABLES
============================================================
The database contains these relevant tables in the ORDERS schema:

- **ORDERS.ORDERS** — Order header records with identifiers, financial totals, status, and timestamps. Explore the table to discover available columns for your staging model.
- **ORDERS.ORDER_LINES** — Order line-level detail with identifiers, pricing, tax, and total amounts. Explore to find columns needed for line-level aggregation.
- **ORDERS.ORDER_CANCELLATIONS** — Records of cancelled orders with identifiers, timestamps, and reasons. Explore to understand the schema.

============================================================
YOUR TASK
============================================================
Create a dbt project that produces reconciled order financial totals.

1) dbt project
   - Create a dbt project in: /app/dbt_project/
   - Include a profiles.yml inside /app/dbt_project/ and ensure dbt is runnable with:
       dbt run --profiles-dir .
   - For DuckDB: path must point to the database at $DUCKDB_PATH
   - For Snowflake: use password authentication (profiles.yml is pre-configured)

2) Create these models:

   STAGING LAYER (schema: staging)
   ----------------------------------------

   a) staging.stg_orders
      Basic staging model for ORDERS.ORDERS

   b) staging.stg_order_lines
      Basic staging model for ORDERS.ORDER_LINES

   c) staging.stg_order_cancellations
      Basic staging model for ORDERS.ORDER_CANCELLATIONS

   INTERMEDIATE LAYER (schema: intermediate)
   ----------------------------------------

   d) intermediate.int_orders_enriched
      Grain: one row per order_id
      Purpose: Enrich orders with line-level aggregates and cancellation status
      Required columns:
        - order_id
        - order_source
        - is_cancelled (1 if order has a cancellation record, 0 otherwise)
        - subtotal (from orders table)
        - grand_total (from orders table)
        - tax_total (TAX_TOTAL from orders table)
        - line_subtotal (SUM of LINE_TOTAL from order_lines for this order)
        - line_tax (SUM of TAX_AMOUNT from order_lines for this order)
        - line_count (count of order lines)
        - has_lines (1 if line_count > 0, 0 otherwise)

   MART LAYER (schema: mart)
   ----------------------------------------

   e) mart.mart_order_totals
      Grain: one row per order_id
      Required columns:
        - order_id
        - order_source
        - is_cancelled (1 if order has a cancellation record, 0 otherwise)
        - header_subtotal (SUBTOTAL from orders table)
        - header_grand_total (GRAND_TOTAL from orders table)
        - line_subtotal (SUM of LINE_TOTAL from order_lines for this order)
        - line_count (count of order lines)
        - subtotal_variance (header_subtotal - line_subtotal)
        - has_variance (1 if subtotal_variance != 0, 0 otherwise)
        - header_tax (TAX_TOTAL from orders table)
        - line_tax (SUM of TAX_AMOUNT from order_lines for this order)
        - tax_variance (header_tax - line_tax)
        - has_tax_variance (1 if tax_variance != 0, 0 otherwise)

   f) mart.mart_revenue_by_source
      Grain: one row per order_source
      Scope: Only non-cancelled orders (orders without a record in ORDER_CANCELLATIONS)
      Required columns:
        - order_source
        - order_count (count of orders)
        - total_revenue (sum of GRAND_TOTAL)
        - total_items (sum of QUANTITY_ORDERED from order_lines)
        - avg_order_value (total_revenue / order_count)

   g) mart.mart_variance_details
      Grain: one row per order_id
      Scope: ONLY orders where subtotal variance OR tax variance exists
             (where header_subtotal != line_subtotal OR header_tax != line_tax)
      Required columns:
        - order_id
        - order_source
        - header_subtotal
        - line_subtotal
        - subtotal_variance (header_subtotal - line_subtotal)
        - subtotal_variance_pct (subtotal_variance / header_subtotal * 100, or 0 if header_subtotal = 0)
        - header_tax
        - line_tax
        - tax_variance (header_tax - line_tax)
        - tax_variance_pct (tax_variance / header_tax * 100, or 0 if header_tax = 0)

============================================================
IMPORTANT SCHEMA NOTE
============================================================
Your dbt models must be created in schemas named exactly: staging, intermediate, mart
(not prefixed with the target schema name)

You may need to create a custom `generate_schema_name` macro to override dbt's default
schema prefixing behavior.

============================================================
GUIDELINES
============================================================
- Handle NULL values appropriately (treat as 0 for calculations)
- Ensure proper JOIN types to handle data quality issues (orphan order lines exist)
- Division by zero should return 0
- Percentage calculations should be rounded appropriately
