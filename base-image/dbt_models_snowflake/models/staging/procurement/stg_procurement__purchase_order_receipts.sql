{{
    config(
        materialized='view',
        tags=['procurement', 'staging']
    )
}}

-- Staging model for PROCUREMENT.PURCHASE_ORDER_RECEIPTS

with source as (
    select * from {{ source('procurement', 'PURCHASE_ORDER_RECEIPTS') }}
),

renamed as (
    select
        trim(receipt_id) as receipt_id,
        trim(receipt_number) as receipt_number,
        trim(po_id) as po_id,
        received_at,
        trim(received_by) as received_by,
        trim(status) as status,
        created_at
    from source
)

select * from renamed
