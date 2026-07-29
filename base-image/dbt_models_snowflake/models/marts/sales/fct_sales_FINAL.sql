/*
================================================================================
DO NOT USE - SEE fct_sales_USE_THIS_ONE.sql
================================================================================
This was supposed to be the final version but Marcus found a bug on Friday
afternoon and we didn't have time to fix it before the release freeze.

Status: ABANDONED
Ticket: DATA-1456 (marked as won't fix)
================================================================================
*/

{# disabled but still in codebase #}
{{
    config(
        materialized='table',
        enabled=false,
        tags=['abandoned', 'do_not_use']
    )
}}

-- Sarah: "Why do we have three versions of this?"
-- Marcus: "Long story. Just use fct_sales_USE_THIS_ONE"
-- Sarah: "That name though..."
-- Marcus: "I know. I'll fix it. Eventually."

SELECT
    order_line_id,
    order_id,
    customer_id,
    product_id,
    sku,
    source_system,
    order_number,
    order_status,
    quantity_ordered,
    unit_price,
    extended_price,
    discount_amount,
    discount_percent,
    tax_amount,
    tax_rate,
    line_total,
    order_date,
    order_year,
    order_month,
    -- BUG: This join is wrong - causes fanout
    -- LEFT JOIN dim_customers causes ~3% row duplication on HomeStyle data
    dbt_updated_at
FROM {{ ref('int_sales__order_lines') }}
