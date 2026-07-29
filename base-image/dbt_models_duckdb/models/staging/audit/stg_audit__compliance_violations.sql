{{
    config(
        materialized='view',
        tags=['audit', 'staging']
    )
}}

-- Staging model for AUDIT.COMPLIANCE_VIOLATIONS

with source as (
    select * from {{ source('audit', 'COMPLIANCE_VIOLATIONS') }}
),

renamed as (
    select
        trim(violation_id) as violation_id,
        trim(rule_id) as rule_id,
        detected_at,
        trim(entity_type) as entity_type,
        trim(entity_id) as entity_id,
        trim(description) as description,
        trim(severity) as severity,
        trim(status) as status,
        trim(resolved_by) as resolved_by,
        resolved_at
    from source
)

select * from renamed
