{{
    config(
        materialized='view',
        tags=['finance', 'staging']
    )
}}

-- Staging model for FINANCE.CUSTOMER_CREDITS

with source as (
    select * from {{ source('finance', 'CUSTOMER_CREDITS') }}
),

renamed as (
    select
        trim(credit_id) as credit_id,
        trim(credit_number) as credit_number,
        trim(customer_id) as customer_id,
        amount,
        balance,
        trim(reason) as reason,
        created_at
    from source
)

select * from renamed
