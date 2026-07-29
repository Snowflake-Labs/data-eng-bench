with source as (
    select * from {{ source('raw_sap', 'cdpos_hist') }}
),

renamed as (
    select
        _ID as _id,
        _LOADED_AT as _loaded_at,
        _SOURCE_SYSTEM as _source_system,
        _SOURCE_TABLE as _source_table,
        _ROW_HASH as _row_hash,
        "_archived_at" as _archived_at
    from source
)

select * from renamed
