{{
    config(
        materialized='view',
        tags=['reference', 'staging']
    )
}}

-- Staging model for REFERENCE.SHIPPING_METHODS

with source as (
    select * from {{ source('reference', 'SHIPPING_METHODS') }}
),

renamed as (
    select
        trim(shipping_method_id) as shipping_method_id,
        trim(shipping_method_code) as shipping_method_code,
        trim(shipping_method_name) as shipping_method_name,
        trim(carrier_id) as carrier_id,
        estimated_days_min,
        estimated_days_max,
        is_express,
        is_active,
        created_at,
        updated_at
    from source
)

select * from renamed
