with source as (
    select * from {{ source('raw_sap', 'pa0002_hist') }}
),

renamed as (
    select
        employee_id as employee_id, employee_number as employee_number,
        first_name as first_name,
        last_name as last_name,
        email as email,
        phone as phone,
        hire_date as hire_date,
        termination_date as termination_date,
        manager_id as manager_id,
        department_id as department_id,
        position_id as position_id,
        employment_type as employment_type,
        status as status,
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
