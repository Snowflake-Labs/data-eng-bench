{{
    config(
        materialized='view',
        tags=['analytics', 'staging']
    )
}}

-- Staging model for ANALYTICS.DIM_GEOGRAPHY

with source as (
    select * from {{ source('analytics', 'DIM_GEOGRAPHY') }}
),

renamed as (
    select
        geography_key,
        trim(country_code) as country_code,
        trim(country_name) as country_name,
        trim(state_code) as state_code,
        trim(state_name) as state_name,
        trim(city) as city,
        trim(postal_code) as postal_code,
        trim(region) as region,
        trim(timezone) as timezone
    from source
)

select * from renamed
