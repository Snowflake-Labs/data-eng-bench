{{
    config(
        materialized='view',
        tags=['reference', 'staging']
    )
}}

-- Staging model for REFERENCE.PAYMENT_METHODS

with source as (
    select * from {{ source('reference', 'PAYMENT_METHODS') }}
),

renamed as (
    select
        trim(payment_method_id) as payment_method_id,
        trim(payment_method_code) as payment_method_code,
        trim(payment_method_name) as payment_method_name,
        trim(payment_type) as payment_type,
        trim(processor_name) as processor_name,
        is_active,
        created_at,
        updated_at
    from source
)

select * from renamed
