with source as (
    select * from {{ source('raw_sfdc', 'feedback_hist') }}
),

renamed as (
    select
        review_id as review_id,
        product_id as product_id,
        variant_id as variant_id,
        customer_id as customer_id,
        order_id as order_id,
        rating as rating,
        review_title as review_title,
        review_text as review_text,
        pros as pros,
        cons as cons,
        is_verified_purchase as is_verified_purchase,
        is_recommended as is_recommended,
        helpful_count as helpful_count,
        not_helpful_count as not_helpful_count,
        media_urls as media_urls,
        status as status,
        moderated_at as moderated_at,
        moderated_by as moderated_by,
        rejection_reason as rejection_reason,
        review_source as review_source,
        reviewer_display_name as reviewer_display_name,
        submitted_at as submitted_at,
        created_at as created_at,
        updated_at as updated_at,
        _loaded_at as _loaded_at,
        _source_system as _source_system,
        _batch_id as _batch_id,
        _row_number as _row_number,
        _row_hash as _row_hash,
        "_archived_at" as _archived_at
    from source
)

select * from renamed
