{{
    config(
        materialized='view',
        tags=['hr', 'staging']
    )
}}

-- Staging model for HR.COST_CENTER_ASSIGNMENTS

with source as (
    select * from {{ source('hr', 'COST_CENTER_ASSIGNMENTS') }}
),

renamed as (
    select
        trim(assignment_id) as assignment_id,
        trim(employee_id) as employee_id,
        trim(cost_center_id) as cost_center_id,
        allocation_percentage,
        effective_from,
        effective_to,
        created_at
    from source
)

select * from renamed
