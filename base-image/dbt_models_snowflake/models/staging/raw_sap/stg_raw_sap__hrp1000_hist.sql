with source as (
    select * from {{ source('raw_sap', 'hrp1000_hist') }}
),

renamed as (
    select
        assignment_id as assignment_id,
        employee_id as employee_id,
        position_id as position_id,
        start_date as start_date,
        end_date as end_date,
        is_primary as is_primary,
        created_at as created_at,
        _loaded_at as _loaded_at,
        _source_system as _source_system,
        _batch_id as _batch_id,
        _row_number as _row_number,
        _row_hash as _row_hash,
        "_archived_at" as _archived_at
    from source
)

select * from renamed
