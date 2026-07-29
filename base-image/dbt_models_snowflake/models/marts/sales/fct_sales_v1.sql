/*
================================================================================
LEGACY MODEL - USE fct_sales INSTEAD
================================================================================
This model is maintained for backwards compatibility with existing reports.
It wraps the current fct_sales model but provides the old column names.

@deprecated since 2024-03-15
@see fct_sales for current implementation
================================================================================
*/

{{
    config(
        materialized='view',
        tags=['legacy', 'compatibility']
    )
}}

-- Compatibility wrapper for old column names
-- TODO: Identify all consumers and migrate them (DATA-1205)

select
    order_line_id as sale_id,
    order_id as order_key,
    customer_id as cust_key,
    product_id as prod_key,
    sku,
    source_system,
    order_number,
    order_status,
    quantity_ordered as qty,
    unit_price as unit_amt,
    line_total as sale_amt,
    discount_amount as discount_amt,
    order_date as sale_date,
    order_year as sale_year,
    order_month as sale_month,
    dbt_updated_at as etl_loaded_at
from {{ ref('fct_sales') }}
