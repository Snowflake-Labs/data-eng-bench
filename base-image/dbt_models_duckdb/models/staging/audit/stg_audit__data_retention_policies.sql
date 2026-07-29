{{
    config(
        materialized='view',
        tags=['audit', 'staging']
    )
}}

-- Staging model for AUDIT.DATA_RETENTION_POLICIES

with source as (
    select * from {{ source('audit', 'DATA_RETENTION_POLICIES') }}
),

renamed as (
    select
        trim(policy_id) as policy_id,
        trim(policy_name) as policy_name,
        trim(entity_type) as entity_type,
        retention_days,
        trim(action) as action,
        is_active,
        created_at
    from source
)

select * from renamed
