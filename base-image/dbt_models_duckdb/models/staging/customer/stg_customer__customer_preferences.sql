{{
    config(
        materialized='view',
        tags=['customer', 'staging']
    )
}}

-- Staging model for CUSTOMER.CUSTOMER_PREFERENCES

with source as (
    select * from {{ source('customer', 'CUSTOMER_PREFERENCES') }}
),

renamed as (
    select
        trim(preference_id) as preference_id,
        trim(customer_id) as customer_id,
        trim(preference_category) as preference_category,
        trim(preference_key) as preference_key,
        trim(preference_value) as preference_value,
        is_opted_in,
        effective_from,
        effective_to,
        trim(source) as source,
        created_at,
        updated_at
    from source
)

select * from renamed
