{{
    config(
        materialized='view',
        tags=['finance', 'staging']
    )
}}

-- Staging model for FINANCE.CUSTOMER_AGING

with source as (
    select * from {{ source('finance', 'CUSTOMER_AGING') }}
),

renamed as (
    select
        trim(aging_id) as aging_id,
        trim(customer_id) as customer_id,
        as_of_date,
        current_amount,
        days_30_amount,
        days_60_amount,
        days_90_amount,
        over_90_amount,
        total_balance,
        created_at
    from source
)

select * from renamed
