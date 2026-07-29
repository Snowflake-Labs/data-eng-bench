{{
    config(
        materialized='view',
        tags=['analytics', 'staging']
    )
}}

-- Staging model for ANALYTICS.FACT_CUSTOMER_INTERACTIONS

with source as (
    select * from {{ source('analytics', 'FACT_CUSTOMER_INTERACTIONS') }}
),

renamed as (
    select
        trim(interaction_key) as interaction_key,
        date_key,
        time_key,
        customer_key,
        employee_key,
        channel_key,
        trim(interaction_type) as interaction_type,
        duration_seconds,
        satisfaction_score,
        resolved
    from source
)

select * from renamed
