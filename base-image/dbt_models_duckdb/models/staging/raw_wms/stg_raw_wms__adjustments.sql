with source as (
    select * from {{ source('raw_wms', 'adjustments') }}
),

renamed as (
    select
        adjustment_id as adjustment_id,
        adjustment_number as adjustment_number,
        warehouse_id as warehouse_id,
        adjustment_type as adjustment_type,
        status as status,
        total_lines as total_lines,
        total_quantity as total_quantity,
        total_value as total_value,
        reason_code as reason_code,
        notes as notes,
        requested_by as requested_by,
        requested_at as requested_at,
        approved_by as approved_by,
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
