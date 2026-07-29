{{
    config(
        materialized='view',
        tags=['finance', 'staging']
    )
}}

-- Staging model for FINANCE.CUSTOMER_INVOICE_LINES

with source as (
    select * from {{ source('finance', 'CUSTOMER_INVOICE_LINES') }}
),

renamed as (
    select
        trim(invoice_line_id) as invoice_line_id,
        trim(invoice_id) as invoice_id,
        trim(order_line_id) as order_line_id,
        trim(description) as description,
        quantity,
        unit_price,
        line_total,
        tax_amount,
        created_at
    from source
)

select * from renamed
