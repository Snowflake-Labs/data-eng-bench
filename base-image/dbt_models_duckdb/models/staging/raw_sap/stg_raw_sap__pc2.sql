with source as (
    select * from {{ source('raw_sap', 'pc2') }}
),

renamed as (
    select
        payroll_run_id as payroll_run_id,
        payroll_period as payroll_period,
        period_start as period_start,
        period_end as period_end,
        pay_date as pay_date,
        status as status,
        total_gross as total_gross,
        total_net as total_net,
        employee_count as employee_count,
        created_at as created_at,
        _loaded_at as _loaded_at,
        _source_system as _source_system,
        _batch_id as _batch_id,
        _row_number as _row_number,
        _row_hash as _row_hash
    from source
)

select * from renamed
