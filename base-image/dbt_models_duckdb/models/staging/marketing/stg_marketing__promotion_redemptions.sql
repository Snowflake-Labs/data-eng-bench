{{
    config(
        materialized='view',
        tags=['marketing', 'staging']
    )
}}

-- Staging model for MARKETING.PROMOTION_REDEMPTIONS

with source as (
    select * from {{ source('marketing', 'PROMOTION_REDEMPTIONS') }}
),

renamed as (
    select
        trim(redemption_id) as redemption_id,
        trim(promotion_id) as promotion_id,
        trim(order_id) as order_id,
        trim(customer_id) as customer_id,
        discount_amount,
        redeemed_at
    from source
)

select * from renamed
