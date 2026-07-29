{{
    config(
        materialized='view',
        tags=['marketing', 'staging']
    )
}}

-- Staging model for MARKETING.COUPONS

with source as (
    select * from {{ source('marketing', 'COUPONS') }}
),

renamed as (
    select
        trim(coupon_id) as coupon_id,
        trim(coupon_code) as coupon_code,
        trim(promotion_id) as promotion_id,
        usage_limit,
        usage_count,
        is_active,
        expires_at,
        created_at
    from source
)

select * from renamed
