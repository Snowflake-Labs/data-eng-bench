with source as (
    select * from {{ source('raw_wms', 'zones_hist') }}
),

renamed as (
    select
        zone_id as zone_id,
        warehouse_id as warehouse_id,
        zone_code as zone_code,
        zone_name as zone_name,
        zone_type as zone_type,
        temperature_controlled as temperature_controlled,
        min_temperature as min_temperature,
        max_temperature as max_temperature,
        capacity_units as capacity_units,
        sort_order as sort_order,
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
