{{
    config(
        materialized='view',
        tags=['reference', 'staging']
    )
}}

-- Staging model for REFERENCE.STATES_PROVINCES

with source as (
    select * from {{ source('reference', 'STATES_PROVINCES') }}
),

renamed as (
    select
        trim(state_province_id) as state_province_id,
        trim(country_id) as country_id,
        trim(state_code) as state_code,
        trim(state_name) as state_name,
        is_active,
        created_at,
        updated_at
    from source
)

select * from renamed
