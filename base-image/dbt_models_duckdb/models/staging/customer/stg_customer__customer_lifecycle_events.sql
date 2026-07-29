{{
    config(
        materialized='view',
        tags=['customer', 'staging']
    )
}}

-- Staging model for CUSTOMER.CUSTOMER_LIFECYCLE_EVENTS

with source as (
    select * from {{ source('customer', 'CUSTOMER_LIFECYCLE_EVENTS') }}
),

renamed as (
    select
        trim(event_id) as event_id,
        trim(customer_id) as customer_id,
        trim(event_type) as event_type,
        event_date,
        event_timestamp,
        trim(previous_status) as previous_status,
        trim(new_status) as new_status,
        trim(event_trigger) as event_trigger,
        event_details,
        created_at
    from source
)

select * from renamed
