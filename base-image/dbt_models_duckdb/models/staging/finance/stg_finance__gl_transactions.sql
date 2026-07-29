{{
    config(
        materialized='view',
        tags=['finance', 'staging']
    )
}}

-- Staging model for FINANCE.GL_TRANSACTIONS

with source as (
    select * from {{ source('finance', 'GL_TRANSACTIONS') }}
),

renamed as (
    select
        trim(transaction_id) as transaction_id,
        trim(transaction_number) as transaction_number,
        trim(account_id) as account_id,
        trim(period_id) as period_id,
        transaction_date,
        debit_amount,
        credit_amount,
        trim(description) as description,
        trim(reference_type) as reference_type,
        trim(reference_id) as reference_id,
        trim(created_by) as created_by,
        created_at
    from source
)

select * from renamed
