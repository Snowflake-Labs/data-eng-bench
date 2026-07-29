with source as (
    select * from {{ source('raw_sap', 'csks') }}
),

renamed as (
    select
        cost_center_id as cost_center_id,
        cost_center_code as cost_center_code,
        cost_center_name as cost_center_name,
        manager_id as manager_id,
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
