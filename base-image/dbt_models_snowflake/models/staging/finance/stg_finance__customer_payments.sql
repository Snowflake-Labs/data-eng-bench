{{
    config(
        materialized='view',
        tags=['finance', 'staging']
    )
}}

-- Staging model for FINANCE.CUSTOMER_PAYMENTS

with source as (
    select * from {{ source('finance', 'CUSTOMER_PAYMENTS') }}
),

renamed as (
    select
        trim(payment_id) as payment_id,
        trim(payment_number) as payment_number,
        trim(customer_id) as customer_id,
        payment_date,
        amount,
        trim(payment_method) as payment_method,
        trim(reference_number) as reference_number,
        trim(status) as status,
        created_at
    from source
)

select * from renamed
