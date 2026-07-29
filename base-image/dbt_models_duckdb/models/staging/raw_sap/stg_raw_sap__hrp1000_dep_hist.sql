with source as (
    select * from {{ source('raw_sap', 'hrp1000_dep_hist') }}
),

renamed as (
    select
        department_id as department_id,
        department_code as department_code,
        department_name as department_name,
        parent_department_id as parent_department_id,
        manager_id as manager_id,
        is_active as is_active,
        created_at as created_at,
        _loaded_at as _loaded_at,
        _source_system as _source_system,
        _batch_id as _batch_id,
        _row_number as _row_number,
        _row_hash as _row_hash,
        _archived_at as _archived_at
    from source
)

select * from renamed
