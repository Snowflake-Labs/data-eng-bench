{{
    config(
        materialized='view',
        tags=['marketing', 'staging']
    )
}}

-- Staging model for MARKETING.PROMOTION_RULES

with source as (
    select * from {{ source('marketing', 'PROMOTION_RULES') }}
),

renamed as (
    select
        trim(rule_id) as rule_id,
        trim(promotion_id) as promotion_id,
        trim(rule_type) as rule_type,
        trim(rule_operator) as rule_operator,
        trim(rule_value) as rule_value,
        created_at
    from source
)

select * from renamed
