with source as (
    select * from {{ source('raw_legacy', 'stscod') }}
),

renamed as (
    select
        status_code_id as status_code_id,
        entity_type as entity_type,
        status_code as status_code,
        status_name as status_name,
        status_description as status_description,
        display_order as display_order,
        is_terminal as is_terminal,
        is_active as is_active,
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
