{{
    config(
        materialized='view',
        tags=['customer', 'staging']
    )
}}

-- Staging model for CUSTOMER.CUSTOMER_TAGS

with source as (
    select * from {{ source('customer', 'CUSTOMER_TAGS') }}
),

renamed as (
    select
        trim(tag_id) as tag_id,
        trim(customer_id) as customer_id,
        trim(tag_name) as tag_name,
        trim(tag_category) as tag_category,
        trim(tag_source) as tag_source,
        applied_at,
        trim(applied_by) as applied_by,
        expires_at,
        is_active
    from source
)

select * from renamed
