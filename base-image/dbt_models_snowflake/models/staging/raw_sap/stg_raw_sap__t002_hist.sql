with source as (
    select * from {{ source('raw_sap', 't002_hist') }}
),

renamed as (
    select
        language_code as language_code,
        language_name as language_name,
        native_name as native_name,
        is_active as is_active,
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
