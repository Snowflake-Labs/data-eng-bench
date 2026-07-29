{{
    config(
        materialized='view',
        tags=['procurement', 'staging']
    )
}}

-- Staging model for PROCUREMENT.PURCHASE_ORDER_RECEIPT_LINES

with source as (
    select * from {{ source('procurement', 'PURCHASE_ORDER_RECEIPT_LINES') }}
),

renamed as (
    select
        trim(receipt_line_id) as receipt_line_id,
        trim(receipt_id) as receipt_id,
        trim(po_line_id) as po_line_id,
        quantity_received,
        quantity_accepted,
        quantity_rejected,
        trim(reject_reason) as reject_reason,
        created_at
    from source
)

select * from renamed
