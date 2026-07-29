with source as (
    select * from {{ source('raw_sap', 'migo_hist') }}
),

renamed as (
    select
        transfer_id as transfer_id,
        transfer_number as transfer_number,
        transfer_type as transfer_type,
        source_type as source_type,
        source_warehouse_id as source_warehouse_id,
        source_store_id as source_store_id,
        dest_type as dest_type,
        dest_warehouse_id as dest_warehouse_id,
        dest_store_id as dest_store_id,
        status as status,
        priority as priority,
        total_lines as total_lines,
        total_quantity as total_quantity,
        total_value as total_value,
        created_by as created_by,
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
