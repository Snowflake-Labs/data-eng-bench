{{
    config(
        materialized='view',
        tags=['finance', 'staging']
    )
}}

-- Staging model for FINANCE.GL_PERIODS

with source as (
    select * from {{ source('finance', 'GL_PERIODS') }}
),

renamed as (
    select
        trim(period_id) as period_id,
        fiscal_year,
        fiscal_quarter,
        fiscal_month,
        trim(period_name) as period_name,
        start_date,
        end_date,
        trim(status) as status,
        created_at
    from source
)

select * from renamed
