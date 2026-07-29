{{
    config(
        materialized='view',
        tags=['digital', 'staging']
    )
}}

-- Staging model for DIGITAL.WISHLIST_ITEMS

with source as (
    select * from {{ source('digital', 'WISHLIST_ITEMS') }}
),

renamed as (
    select
        trim(wishlist_item_id) as wishlist_item_id,
        trim(wishlist_id) as wishlist_id,
        trim(variant_id) as variant_id,
        added_at,
        trim(notes) as notes,
        priority
    from source
)

select * from renamed
