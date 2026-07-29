{{
    config(
        materialized='view',
        tags=['audit', 'staging']
    )
}}

-- Staging model for AUDIT.COMPLIANCE_RULES

with source as (
    select * from {{ source('audit', 'COMPLIANCE_RULES') }}
),

renamed as (
    select
        trim(rule_id) as rule_id,
        trim(rule_code) as rule_code,
        trim(rule_name) as rule_name,
        trim(rule_type) as rule_type,
        trim(description) as description,
        trim(severity) as severity,
        is_active,
        created_at
    from source
)

select * from renamed
