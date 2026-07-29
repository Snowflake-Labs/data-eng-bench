with source as (
    select * from {{ source('raw_pos', 'tenders') }}
),

renamed as (
    select
        payment_id as payment_id,
        order_id as order_id,
        payment_method_id as payment_method_id,
        payment_method as payment_method,
        amount as amount,
        currency_code as currency_code,
        status as status,
        transaction_id as transaction_id,
        authorization_code as authorization_code,
        card_last_four as card_last_four,
        card_type as card_type,
        processed_at as processed_at,
        created_at as created_at,
        updated_at as updated_at,
        _loaded_at as _loaded_at,
        _source_system as _source_system,
        _batch_id as _batch_id,
        _row_number as _row_number,
        _row_hash as _row_hash
    from source
)

select * from renamed
