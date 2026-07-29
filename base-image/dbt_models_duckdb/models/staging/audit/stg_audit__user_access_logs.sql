{{
    config(
        materialized='view',
        tags=['audit', 'staging']
    )
}}

-- Staging model for AUDIT.USER_ACCESS_LOGS

with source as (
    select * from {{ source('audit', 'USER_ACCESS_LOGS') }}
),

renamed as (
    select
        trim(access_id) as access_id,
        trim(user_id) as user_id,
        trim(user_email) as user_email,
        trim(access_type) as access_type,
        access_timestamp,
        trim(ip_address) as ip_address,
        trim(user_agent) as user_agent,
        trim(location) as location,
        success,
        trim(failure_reason) as failure_reason
    from source
)

select * from renamed
