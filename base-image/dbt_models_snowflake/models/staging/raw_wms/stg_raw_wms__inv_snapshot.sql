with source as (
    select * from {{ source('raw_wms', 'inv_snapshot') }}
),

renamed as (
    select
        inventory_id as inventory_id,
        variant_id as variant_id,
        location_type as location_type,
        warehouse_id as warehouse_id,
        store_id as store_id,
        location_id as location_id,
        quantity_on_hand as quantity_on_hand,
        quantity_available as quantity_available,
        quantity_reserved as quantity_reserved,
        quantity_incoming as quantity_incoming,
        quantity_on_hold as quantity_on_hold,
        unit_cost as unit_cost,
        inventory_status as inventory_status,
        last_counted_at as last_counted_at,
        last_received_at as last_received_at,
        last_picked_at as last_picked_at,
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
