with source as (
    select * from {{ source('raw_sap', 'tcurc_hist') }}
),

renamed as (
    select
        currency_code as currency_code,
        currency_name as currency_name,
        currency_symbol as currency_symbol,
        decimal_places as decimal_places,
        is_active as is_active,
        created_at as created_at,
        updated_at as updated_at,
        _loaded_at as _loaded_at,
        _source_system as _source_system,
        _batch_id as _batch_id,
        _row_number as _row_number,
        _row_hash as _row_hash,
        _archived_at as _archived_at
    from source
)

select * from renamed
