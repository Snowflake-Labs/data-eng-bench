{{
    config(
        materialized='view',
        tags=['audit', 'staging']
    )
}}

-- Staging model for AUDIT.AUDIT_LOGS

with source as (
    select * from {{ source('audit', 'AUDIT_LOGS') }}
),

renamed as (
    select
        trim(audit_id) as audit_id,
        trim(event_type) as event_type,
        event_timestamp,
        trim(user_id) as user_id,
        trim(user_email) as user_email,
        trim(table_name) as table_name,
        trim(record_id) as record_id,
        trim(action) as action,
        old_values,
        new_values,
        trim(ip_address) as ip_address,
        trim(user_agent) as user_agent,
        created_at
    from source
)

select * from renamed
