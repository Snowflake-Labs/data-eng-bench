with source as (
    select * from {{ source('raw_sap', 'catsdb') }}
),

renamed as (
    select
        entry_id as entry_id,
        employee_id as employee_id,
        entry_date as entry_date,
        clock_in as clock_in,
        clock_out as clock_out,
        break_minutes as break_minutes,
        hours_worked as hours_worked,
        entry_type as entry_type,
        status as status,
        created_at as created_at,
        _loaded_at as _loaded_at,
        _source_system as _source_system,
        _batch_id as _batch_id,
        _row_number as _row_number,
        _row_hash as _row_hash
    from source
)

select * from renamed
