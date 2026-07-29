{{
    config(
        materialized='view',
        tags=['digital', 'staging']
    )
}}

-- Staging model for DIGITAL.MARKETPLACE_LISTINGS

with source as (
    select * from {{ source('digital', 'MARKETPLACE_LISTINGS') }}
),

renamed as (
    select
        trim(listing_id) as listing_id,
        trim(channel_id) as channel_id,
        trim(product_id) as product_id,
        trim(variant_id) as variant_id,
        trim(external_id) as external_id,
        trim(listing_title) as listing_title,
        listing_price,
        trim(status) as status,
        created_at,
        updated_at
    from source
)

select * from renamed
