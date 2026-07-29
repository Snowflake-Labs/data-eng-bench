{{
    config(
        materialized='view',
        tags=['procurement', 'staging']
    )
}}

-- Staging model for PROCUREMENT.SUPPLIER_INVOICE_LINES

with source as (
    select * from {{ source('procurement', 'SUPPLIER_INVOICE_LINES') }}
),

renamed as (
    select
        trim(invoice_line_id) as invoice_line_id,
        trim(invoice_id) as invoice_id,
        trim(po_line_id) as po_line_id,
        trim(description) as description,
        quantity,
        unit_price,
        line_total,
        created_at
    from source
)

select * from renamed
