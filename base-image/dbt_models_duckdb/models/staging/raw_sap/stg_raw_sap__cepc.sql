with source as (
    select * from {{ source('raw_sap', 'cepc') }}
),

renamed as (
    select
        profit_center_id as profit_center_id,
        profit_center_code as profit_center_code,
        profit_center_name as profit_center_name,
        is_active as is_active,
        created_at as created_at,
        _loaded_at as _loaded_at,
        _source_system as _source_system,
        _batch_id as _batch_id,
        _row_number as _row_number,
        _row_hash as _row_hash
    from source
)

select * from renamed
