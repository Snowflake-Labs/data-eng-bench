{{
    config(
        materialized='view',
        tags=['digital', 'staging']
    )
}}

-- Staging model for DIGITAL.WEB_EVENTS

with source as (
    select * from {{ source('digital', 'WEB_EVENTS') }}
),

renamed as (
    select
        trim(event_id) as event_id,
        trim(session_id) as session_id,
        trim(event_type) as event_type,
        trim(event_name) as event_name,
        event_timestamp,
        trim(page_url) as page_url,
        trim(element_id) as element_id,
        trim(element_class) as element_class,
        trim(product_id) as product_id,
        event_value,
        event_data,
        created_at
    from source
)

select * from renamed
