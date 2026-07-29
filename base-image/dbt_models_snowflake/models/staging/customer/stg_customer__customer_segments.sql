{{
    config(
        materialized='view',
        tags=['customer', 'staging']
    )
}}

-- Staging model for CUSTOMER.CUSTOMER_SEGMENTS

with source as (
    select * from {{ source('customer', 'CUSTOMER_SEGMENTS') }}
),

renamed as (
    select
        trim(segment_id) as segment_id,
        trim(segment_code) as segment_code,
        trim(segment_name) as segment_name,
        trim(segment_type) as segment_type,
        trim(segment_description) as segment_description,
        segment_criteria,
        is_dynamic,
        trim(refresh_frequency) as refresh_frequency,
        last_refreshed_at,
        member_count,
        is_active,
        created_at,
        updated_at
    from source
)

select * from renamed
