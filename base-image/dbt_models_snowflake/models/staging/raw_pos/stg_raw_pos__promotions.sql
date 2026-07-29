with source as (
    select * from {{ source('raw_pos', 'promotions') }}
),

renamed as (
    select
        promotion_id as promotion_id,
        promotion_code as promotion_code,
        promotion_name as promotion_name,
        promotion_type as promotion_type,
        discount_type as discount_type,
        discount_value as discount_value, min_purchase as min_purchase,
        max_discount as max_discount,
        start_date as start_date,
        end_date as end_date,
        is_active as is_active,
        created_at as created_at,
        _loaded_at as _loaded_at,
        _source_system as _source_system,
        _batch_id as _batch_id, _row_number as _row_number,
        _row_hash as _row_hash
    from source
)

select * from renamed
