with source as (
    select * from {{ source('raw_wms', 'warehouses') }}
),

renamed as (
    select
        warehouse_id as warehouse_id,
        warehouse_code as warehouse_code,
        warehouse_name as warehouse_name,
        warehouse_type as warehouse_type,
        address_line_1 as address_line_1,
        city as city,
        state_province as state_province,
        postal_code as postal_code,
        country_code as country_code,
        latitude as latitude,
        longitude as longitude,
        timezone as timezone,
        phone as phone,
        email as email,
        manager_name as manager_name,
        square_footage as square_footage,
        max_capacity_units as max_capacity_units,
        opened_date as opened_date,
        priority as priority,
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
