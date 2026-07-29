with source as (
    select * from {{ source('raw_legacy', 'prclst') }}
),

renamed as (
    select
        price_id as price_id,
        variant_id as variant_id,
        price_type as price_type,
        currency_code as currency_code,
        price_amount as price_amount,
        compare_at_price as compare_at_price,
        cost_price as cost_price,
        min_qty as min_qty,
        max_qty as max_qty,
        customer_tier_id as customer_tier_id,
        channel_id as channel_id,
        effective_from as effective_from,
        effective_to as effective_to,
        is_active as is_active,
        created_at as created_at,
        updated_at as updated_at,
        created_by as created_by,
        _loaded_at as _loaded_at,
        _source_system as _source_system,
        _batch_id as _batch_id,
        _row_number as _row_number,
        _row_hash as _row_hash
    from source
)

select * from renamed
