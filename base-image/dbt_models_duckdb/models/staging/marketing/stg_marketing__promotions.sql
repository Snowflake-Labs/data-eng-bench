{{
    config(
        materialized='view',
        tags=['marketing', 'staging']
    )
}}

-- Staging model for MARKETING.PROMOTIONS

with source as (
    select * from {{ source('marketing', 'PROMOTIONS') }}
),

renamed as (
    select
        trim(promotion_id) as promotion_id,
        trim(promotion_code) as promotion_code,
        trim(promotion_name) as promotion_name,
        trim(promotion_type) as promotion_type,
        trim(discount_type) as discount_type,
        discount_value,
        min_purchase,
        max_discount,
        start_date,
        end_date,
        is_active,
        created_at
    from source
)

select * from renamed
