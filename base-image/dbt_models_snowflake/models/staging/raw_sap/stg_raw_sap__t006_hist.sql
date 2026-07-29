with source as (
    select * from {{ source('raw_sap', 't006_hist') }}
),

renamed as (
    select
        uom_code as uom_code,
        uom_name as uom_name,
        uom_type as uom_type,
        base_uom_code as base_uom_code,
        conversion_factor as conversion_factor,
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
