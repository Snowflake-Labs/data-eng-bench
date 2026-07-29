{{
    config(
        materialized='view',
        tags=['finance', 'staging']
    )
}}

-- Staging model for FINANCE.TAX_RATES

with source as (
    select * from {{ source('finance', 'TAX_RATES') }}
),

renamed as (
    select
        trim(tax_rate_id) as tax_rate_id,
        trim(tax_code) as tax_code,
        trim(tax_name) as tax_name,
        trim(tax_type) as tax_type,
        rate,
        trim(country_code) as country_code,
        trim(state_code) as state_code,
        effective_from,
        effective_to,
        is_active,
        created_at
    from source
)

select * from renamed
