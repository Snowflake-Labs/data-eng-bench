{{
    config(
        materialized='view',
        tags=['customer', 'staging']
    )
}}

-- Staging model for CUSTOMER.CUSTOMER_SEGMENT_MEMBERS

with source as (
    select * from {{ source('customer', 'CUSTOMER_SEGMENT_MEMBERS') }}
),

renamed as (
    select
        trim(membership_id) as membership_id,
        trim(customer_id) as customer_id,
        trim(segment_id) as segment_id,
        added_date,
        removed_date,
        score,
        is_active,
        created_at,
        updated_at
    from source
)

select * from renamed
