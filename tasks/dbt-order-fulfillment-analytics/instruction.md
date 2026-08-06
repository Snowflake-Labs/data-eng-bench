You are building an analytics layer for order fulfillment and return analysis using dbt.

IMPORTANT:
- This database contains many schemas/tables that are NOT part of this task.
- For this task, treat the following schema as the raw source-of-truth:
  - ORDERS.*
- You must create your new models in schemas named exactly:
  - staging
  - intermediate
  - marts

  Note: dbt prepends the target schema to custom schema names by default, so to create models in schemas named **exactly** `staging`, `intermediate`, and `marts` (not prefixed), override the `generate_schema_name` macro (e.g. in `macros/generate_schema_name.sql`).

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

============================================================
SOURCE TABLES
============================================================
The database contains source tables organized in the ORDERS schema. Explore these tables to understand available columns:

- ORDERS.ORDERS - Order header records with identifiers, status fields, monetary amounts, and timestamp fields
- ORDERS.ORDER_LINES - Line-item detail for each order with quantities and amounts
- ORDERS.SHIPMENTS - Shipment records with carrier, status, and timestamp information
- ORDERS.SHIPMENT_LINES - Line-item detail for each shipment
- ORDERS.ORDER_STATUS_HISTORY - History of status transitions for orders
- ORDERS.RETURNS - Return header records with status, type, refund details and timestamps
- ORDERS.RETURN_LINES - Line-item detail for each return

============================================================
YOUR TASK
============================================================
Add new staging, intermediate, and mart models for order fulfillment analytics to the existing dbt project.

1) dbt project
   - An existing dbt project is located at:
     - DuckDB: `/app/dbt_models_duckdb/`
     - Snowflake: `/app/dbt_models_snowflake/`
   - The project already has dbt_project.yml configured
   - Sources for ORDERS schema are already defined in models/staging/orders/_sources.yml
   - First install dependencies with: dbt deps
   - Then run dbt commands with: dbt run --select model_name
   - Add your NEW models to the existing project structure under models/

2) Staging models (schema: staging)
   Create these 6 NEW models in models/staging/orders/:
     - staging.stg_orders
     - staging.stg_order_lines
     - staging.stg_shipments
     - staging.stg_shipment_lines
     - staging.stg_order_status_history
     - staging.stg_returns

   NOTE: The existing project has similar staging models with different naming (e.g., stg_orders__orders).
   You must create NEW models with the exact names above for this task.

3) Intermediate models (schema: intermediate)
   Create these NEW models in models/intermediate/:

   - intermediate.int_order_lifecycle
     Grain: one row per order_id
     Required columns:
       order_id, order_number, customer_id, order_type, order_source,
       status, grand_total, ordered_at,
       first_status_change_at (earliest status change timestamp),
       time_to_first_ship_hours (hours from ordered_at to first shipment shipped_at, NULL if never shipped),
       time_to_delivery_hours (hours from ordered_at to delivered_at, NULL if not delivered),
       status_change_count (total number of status changes for this order)

   - intermediate.int_shipment_performance
     Grain: one row per shipment_id
     Required columns:
       shipment_id, shipment_number, order_id, warehouse_id, carrier_id,
       status, shipped_at, delivered_at,
       items_in_shipment (count of shipment lines),
       total_quantity_shipped (sum of quantity_shipped from shipment_lines),
       shipping_cost,
       transit_time_hours (hours from shipped_at to delivered_at, NULL if not delivered)

   - intermediate.int_order_fulfillment_status
     Grain: one row per order_id
     Required columns:
       order_id, order_number, ordered_at,
       total_lines (count of order lines),
       total_quantity_ordered (sum of quantity_ordered),
       total_quantity_shipped (sum of quantity_shipped),
       total_quantity_returned (sum of quantity_returned),
       fulfillment_pct (percentage of ordered quantity that has been shipped),
       is_fully_fulfilled (1 if fully fulfilled, else 0),
       is_partially_fulfilled (1 if partially fulfilled but not fully fulfilled, else 0)

   - intermediate.int_order_revenue_summary
     Grain: one row per order_id
     Scope: Only include orders where status != 'CANCELLED' AND ordered_at IS NOT NULL AND order has at least one order line
     Required columns:
       order_id, order_date (DATE of ordered_at), warehouse_id,
       line_item_count (count of order lines for this order),
       gross_revenue (sum of line item totals for this order),
       shipping_revenue (shipping cost for this order),
       total_revenue (gross_revenue + shipping_revenue)

4) Mart models (schema: marts)
   Create these NEW models in models/marts/:

   - marts.mart_fulfillment_metrics
     Grain: one row per (warehouse_id, order_date) combination where order_date is DATE(ordered_at)
     Required columns:
       warehouse_id, order_date,
       total_orders (count of distinct orders),
       total_order_value (sum of total order revenue),
       total_shipments (count of shipments),
       orders_fully_fulfilled (count of orders where is_fully_fulfilled = 1),
       orders_partially_fulfilled (count of orders where is_partially_fulfilled = 1),
       fulfillment_rate (orders_fully_fulfilled / total_orders * 100),
       avg_time_to_ship_hours (average time_to_first_ship_hours),
       avg_time_to_delivery_hours (average time_to_delivery_hours)

   - marts.mart_return_analysis
     Grain: one row per (return_type, return_month) combination where return_month is first day of month of requested_at
     Required columns:
       return_type, return_month,
       total_returns (count of returns),
       total_refund_amount (sum of refund amounts),
       avg_refund_amount (average refund amount),
       returns_processed (count where status = 'PROCESSED'),
       returns_rejected (count where status = 'REJECTED'),
       processing_rate (returns_processed / total_returns * 100),
       avg_processing_time_days (average days from requested_at to processed_at, for processed returns only)

   - marts.mart_carrier_performance
     Grain: one row per carrier_id
     Required columns:
       carrier_id,
       total_shipments (count of shipments),
       shipments_delivered (count where status = 'DELIVERED'),
       shipments_failed (count where status = 'FAILED'),
       in_transit_shipments (count where status = 'IN_TRANSIT'),
       delivery_rate (shipments_delivered / total_shipments * 100),
       failed_shipment_rate (shipments_failed / total_shipments * 100),
       total_shipping_cost (sum of shipping_cost),
       avg_shipping_cost (average shipping_cost),
       avg_transit_time_hours_delivered_only (average transit_time_hours for status='DELIVERED' AND transit_time_hours IS NOT NULL),
       on_time_delivery_count (count where status='DELIVERED' AND transit_time_hours <= 120)

   - marts.mart_order_status_flow
     Grain: one row per (old_status, new_status) combination (exclude rows where old_status OR new_status is NULL)
     Required columns:
       old_status, new_status,
       transition_count (count of transitions),
       unique_orders (count of distinct orders with this transition),
       avg_time_in_old_status_hours (average hours orders spent in old_status before transitioning),
       pct_of_all_transitions (this transition_count / total transitions * 100)

   - marts.mart_daily_revenue
     Grain: one row per order_date (DATE of ordered_at)
     Scope: Only include orders where:
       - STATUS is NOT 'CANCELLED'
       - ORDERED_AT is NOT NULL (required for date grouping)
       - Order has at least one order line (orders without line items have no revenue)
     Required columns:
       order_date,
       order_count (count of orders that have order lines),
       line_item_count (total count of order line items),
       gross_revenue (sum of line item totals),
       shipping_revenue (sum of shipping costs),
       total_revenue (gross_revenue + shipping_revenue),
       avg_order_value (total_revenue / order_count)

============================================================
NOTES
============================================================
- All models must handle NULL values appropriately
- Percentage calculations should handle division by zero
- Time calculations should use appropriate timestamp functions
- Ensure all grain requirements are met (no duplicate key combinations)
- Reference your staging models using {{ ref('stg_orders') }} etc.
- Use the existing sources definition: {{ source('orders', 'ORDERS') }}

## Guidelines

- Use DATEDIFF for time difference calculations
- Use CAST(... AS DOUBLE) for division to avoid integer truncation
