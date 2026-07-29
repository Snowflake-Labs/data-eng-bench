{{
    config(
        materialized='view',
        tags=['hr', 'staging']
    )
}}

-- Staging model for HR.ORG_HIERARCHY

with source as (
    select * from {{ source('hr', 'ORG_HIERARCHY') }}
),

renamed as (
    select
        trim(hierarchy_id) as hierarchy_id,
        trim(employee_id) as employee_id,
        trim(manager_id) as manager_id,
        level,
        trim(path) as path,
        effective_from,
        effective_to,
        created_at
    from source
)

select * from renamed
