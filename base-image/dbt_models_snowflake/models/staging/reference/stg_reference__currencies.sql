{{
    config(
        materialized='view',
        tags=['reference', 'staging']
    )
}}

-- Staging model for REFERENCE.CURRENCIES

with source as (
    select * from {{ source('reference', 'CURRENCIES') }}
),

renamed as (
    select
        trim(currency_code) as currency_code,
        trim(currency_name) as currency_name,
        trim(currency_symbol) as currency_symbol,
        decimal_places,
        is_active,
        created_at,
        updated_at
    from source
)

select * from renamed
