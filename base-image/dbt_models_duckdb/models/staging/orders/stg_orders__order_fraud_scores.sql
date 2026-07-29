{{
    config(
        materialized='view',
        tags=['orders', 'staging']
    )
}}

-- Staging model for ORDERS.ORDER_FRAUD_SCORES

with source as (
    select * from {{ source('orders', 'ORDER_FRAUD_SCORES') }}
),

renamed as (
    select
        trim(fraud_score_id) as fraud_score_id,
        trim(order_id) as order_id,
        score,
        trim(risk_level) as risk_level,
        trim(provider) as provider,
        rule_hits,
        trim(ip_country) as ip_country,
        trim(reviewed_by) as reviewed_by,
        reviewed_at,
        created_at
    from source
)

select * from renamed
