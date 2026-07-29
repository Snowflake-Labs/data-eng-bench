{{
    config(
        materialized='view',
        tags=['reference', 'staging']
    )
}}

-- Staging model for REFERENCE.TIMEZONES

with source as (
    select * from {{ source('reference', 'TIMEZONES') }}
),

renamed as (
    select
        trim(timezone_id) as timezone_id,
        trim(timezone_name) as timezone_name,
        trim(utc_offset) as utc_offset,
        uses_dst,
        is_active,
        created_at,
        updated_at
    from source
)

select * from renamed
