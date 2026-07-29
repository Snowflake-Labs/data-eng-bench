with source as (
    select * from {{ source('raw_pos', 'coupon_usage') }}
),

renamed as (
    select
        redemption_id as redemption_id,
        coupon_id as coupon_id,
        order_id as order_id,
        customer_id as customer_id,
        discount_amount as discount_amount,
        redeemed_at as redeemed_at,
        _loaded_at as _loaded_at,
        _source_system as _source_system,
        _batch_id as _batch_id,
        _row_number as _row_number,
        _row_hash as _row_hash
    from source
)

select * from renamed
