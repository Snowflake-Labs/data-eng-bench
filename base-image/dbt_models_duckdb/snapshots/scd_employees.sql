{%snapshot scd_employees%}

{{
    config(
        target_schema='snapshots',
        unique_key='employee_id',
        strategy='timestamp',
        updated_at='updated_at',
    )
}}

select * from {{ source('hr', 'EMPLOYEES') }}

{%endsnapshot%}
