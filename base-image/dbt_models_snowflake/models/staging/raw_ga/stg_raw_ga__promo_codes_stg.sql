with source as (
    select * from {{ source('raw_ga', 'promo_codes_stg') }}
),

renamed as (
    select
        coupon_id as coupon_id,
        coupon_code as coupon_code,
        promotion_id as promotion_id,
        usage_limit as usage_limit,
        usage_count as usage_count,
        is_active as is_active,
        expires_at as expires_at,
        created_at as created_at,
        _loaded_at as _loaded_at,
        _source_system as _source_system,
        _batch_id as _batch_id,
        _row_number as _row_number,
        _row_hash as _row_hash,
        TRIM("_status") AS _status
    from source
)

select * from renamed
