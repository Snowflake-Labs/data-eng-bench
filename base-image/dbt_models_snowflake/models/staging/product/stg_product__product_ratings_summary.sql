{{
    config(
        materialized='view',
        tags=['product', 'staging']
    )
}}

-- Staging model for PRODUCT.PRODUCT_RATINGS_SUMMARY

with source as (
    select * from {{ source('product', 'PRODUCT_RATINGS_SUMMARY') }}
),

renamed as (
    select
        trim(summary_id) as summary_id,
        trim(product_id) as product_id,
        total_reviews,
        average_rating,
        rating_1_count,
        rating_2_count,
        rating_3_count,
        rating_4_count,
        rating_5_count,
        recommend_percentage,
        last_review_date,
        last_calculated_at
    from source
)

select * from renamed
