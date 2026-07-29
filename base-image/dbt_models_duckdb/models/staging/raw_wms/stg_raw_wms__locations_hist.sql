with source as (
    select * from {{ source('raw_wms', 'locations_hist') }}
),

renamed as (
    select
        location_id as location_id,
        warehouse_id as warehouse_id,
        zone_id as zone_id,
        location_code as location_code,
        location_barcode as location_barcode,
        aisle as aisle,
        rack as rack,
        shelf as shelf,
        location_type as location_type,
        is_pickable as is_pickable,
        is_receivable as is_receivable,
        max_weight as max_weight,
        pick_sequence as pick_sequence,
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
