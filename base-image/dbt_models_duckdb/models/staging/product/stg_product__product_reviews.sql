{{
    config(
        materialized='view',
        tags=['product', 'staging']
    )
}}

-- Staging model for PRODUCT.PRODUCT_REVIEWS

with source as (
    select * from {{ source('product', 'PRODUCT_REVIEWS') }}
),

renamed as (
    select
        trim(review_id) as review_id,
        trim(product_id) as product_id,
        trim(variant_id) as variant_id,
        trim(customer_id) as customer_id,
        trim(order_id) as order_id,
        rating,
        trim(review_title) as review_title,
        trim(review_text) as review_text,
        trim(pros) as pros,
        trim(cons) as cons,
        is_verified_purchase,
        is_recommended,
        helpful_count,
        not_helpful_count,
        media_urls,
        trim(status) as status,
        moderated_at,
        trim(moderated_by) as moderated_by,
        trim(rejection_reason) as rejection_reason,
        trim(review_source) as review_source,
        trim(reviewer_display_name) as reviewer_display_name,
        submitted_at,
        created_at,
        updated_at
    from source
)

select * from renamed
