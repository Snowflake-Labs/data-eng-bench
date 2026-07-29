{{
    config(
        materialized='view',
        tags=['hr', 'staging']
    )
}}

-- Staging model for HR.EMPLOYEE_COMPENSATION

with source as (
    select * from {{ source('hr', 'EMPLOYEE_COMPENSATION') }}
),

renamed as (
    select
        trim(compensation_id) as compensation_id,
        trim(employee_id) as employee_id,
        trim(compensation_type) as compensation_type,
        amount,
        trim(currency_code) as currency_code,
        trim(frequency) as frequency,
        effective_from,
        effective_to,
        created_at
    from source
)

select * from renamed
