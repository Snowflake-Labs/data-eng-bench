{{
    config(
        materialized='view',
        tags=['marketing', 'staging']
    )
}}

-- Staging model for MARKETING.LOYALTY_PROGRAMS

with source as (
    select * from {{ source('marketing', 'LOYALTY_PROGRAMS') }}
),

renamed as (
    select
        trim(program_id) as program_id,
        trim(program_name) as program_name,
        trim(program_type) as program_type,
        points_per_dollar,
        points_value,
        is_active,
        created_at
    from source
)

select * from renamed
