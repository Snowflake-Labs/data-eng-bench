{{
    config(
        materialized='view',
        tags=['finance', 'staging']
    )
}}

-- Staging model for FINANCE.CURRENCY_EXCHANGE_RATES

with source as (
    select * from {{ source('finance', 'CURRENCY_EXCHANGE_RATES') }}
),

renamed as (
    select
        trim(rate_id) as rate_id,
        trim(from_currency) as from_currency,
        trim(to_currency) as to_currency,
        exchange_rate,
        effective_date,
        trim(source) as source,
        created_at
    from source
)

select * from renamed
