{{
    config(
        materialized='view',
        tags=['procurement', 'staging']
    )
}}

-- Staging model for PROCUREMENT.PURCHASE_ORDER_LINES

with source as (
    select * from {{ source('procurement', 'PURCHASE_ORDER_LINES') }}
),

renamed as (
    select
        trim(po_line_id) as po_line_id,
        trim(po_id) as po_id,
        line_number,
        trim(variant_id) as variant_id,
        trim(sku) as sku,
        quantity_ordered,
        quantity_received,
        unit_price,
        line_total,
        created_at
    from source
)

select * from renamed
