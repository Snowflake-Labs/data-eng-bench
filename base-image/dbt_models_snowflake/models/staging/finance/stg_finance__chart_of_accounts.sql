{{
    config(
        materialized='view',
        tags=['finance', 'staging']
    )
}}

-- Staging model for FINANCE.CHART_OF_ACCOUNTS

with source as (
    select * from {{ source('finance', 'CHART_OF_ACCOUNTS') }}
),

renamed as (
    select
        trim(account_id) as account_id,
        trim(account_number) as account_number,
        trim(account_name) as account_name,
        trim(account_type) as account_type,
        trim(account_subtype) as account_subtype,
        trim(parent_account_id) as parent_account_id,
        is_active,
        created_at
    from source
)

select * from renamed
