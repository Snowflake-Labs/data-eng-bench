{{
    config(
        materialized='view',
        tags=['reference', 'staging']
    )
}}

-- Staging model for REFERENCE.COUNTRIES

with source as (
    select * from {{ source('reference', 'COUNTRIES') }}
),

renamed as (
    select
        trim(country_id) as country_id,
        trim(country_code_2) as country_code_2,
        trim(country_name) as country_name,
        trim(continent) as continent,
        trim(currency_code) as currency_code,
        is_active,
        created_at,
        updated_at
    from source
)

select * from renamed
