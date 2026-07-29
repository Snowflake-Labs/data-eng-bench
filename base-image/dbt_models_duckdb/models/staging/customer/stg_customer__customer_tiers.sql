{{
    config(
        materialized='view',
        tags=['customer', 'staging']
    )
}}

-- Staging model for CUSTOMER.CUSTOMER_TIERS

with source as (
    select * from {{ source('customer', 'CUSTOMER_TIERS') }}
),

renamed as (
    select
        trim(tier_id) as tier_id,
        trim(tier_code) as tier_code,
        trim(tier_name) as tier_name,
        tier_level,
        min_points_required,
        min_spend_required,
        points_multiplier,
        discount_percentage,
        free_shipping,
        trim(benefits_description) as benefits_description,
        trim(tier_color) as tier_color,
        trim(tier_icon) as tier_icon,
        is_active,
        created_at,
        updated_at
    from source
)

select * from renamed
