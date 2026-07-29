{{
    config(
        materialized='view',
        tags=['procurement', 'staging']
    )
}}

-- Staging model for PROCUREMENT.PURCHASE_CONTRACT_ITEMS

with source as (
    select * from {{ source('procurement', 'PURCHASE_CONTRACT_ITEMS') }}
),

renamed as (
    select
        trim(item_id) as item_id,
        trim(contract_id) as contract_id,
        trim(variant_id) as variant_id,
        unit_price,
        min_quantity,
        max_quantity,
        created_at
    from source
)

select * from renamed
