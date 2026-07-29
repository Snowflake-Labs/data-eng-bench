-- dim_customer_v2: Transitional model
-- Created during customer MDM project
-- Adds unified_customer_id but preserves legacy fields

-- HACK: This should reference the MDM golden record table
-- but that's not ready yet, so we're using a surrogate key

{{
    config(
        materialized='table',
        tags=['customer', 'mdm', 'transitional']
    )
}}

with customers as (
    select * from {{ ref('dim_customers') }}
),

-- FIXME: Replace with actual MDM lookup when available
mdm_placeholder as (
    select
        customer_id,
        customer_id as unified_customer_id  -- Same for now
    from customers
)

select
    c.*,
    m.unified_customer_id
from customers c
left join mdm_placeholder m on c.customer_id = m.customer_id
